package com.github.blueboytm.flutter_v2ray.v2ray.services;

import android.app.Service;
import android.content.Intent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.IntentFilter;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.VpnService;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import com.github.blueboytm.flutter_v2ray.v2ray.core.V2rayCoreManager;
import com.github.blueboytm.flutter_v2ray.v2ray.interfaces.V2rayServicesListener;
import com.github.blueboytm.flutter_v2ray.v2ray.utils.AppConfigs;
import com.github.blueboytm.flutter_v2ray.v2ray.utils.V2rayConfig;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileDescriptor;
import java.io.OutputStream;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class V2rayVPNService extends VpnService implements V2rayServicesListener {
    private V2rayDelayReceiver delayReceiver;
    private HandlerThread stopCommandThread;
    private BroadcastReceiver stopCommandReceiver;

    private ParcelFileDescriptor mInterface;
    private Process process;
    private V2rayConfig v2rayConfig;
    private volatile boolean isRunning = false;
    private volatile boolean tunProcessStarted = false;
    private boolean stoppingAllProcesses = false;
    private static final String TAG = "VPN_SERVICE";

    // IRNet patch, Xray TUN mode (V2rayConfig.XRAY_TUN): the interface Xray's
    // own connections leave by, and what follows the network as it changes.
    private volatile String outboundIface;
    private ConnectivityManager.NetworkCallback underlyingCallback;
    private ExecutorService coreRestarts;

    @Override
    public void onCreate() {
        super.onCreate();
        stopCommandThread = new HandlerThread("V2Ray_VpnControl");
        stopCommandThread.start();
        stopCommandReceiver = new BroadcastReceiver() {
            @Override public void onReceive(Context context, Intent intent) {
                if (intent == null || !"VPN_TUN".equals(intent.getStringExtra("MODE"))) return;
                Log.i(TAG, "Received direct STOP command in daemon process");
                stopAllProcess();
            }
        };
        IntentFilter stopFilter = new IntentFilter(
                com.github.blueboytm.flutter_v2ray.v2ray.V2rayConnectionCoordinator.ACTION_STOP_DAEMON);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(stopCommandReceiver, stopFilter, null,
                    new Handler(stopCommandThread.getLooper()), Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(stopCommandReceiver, stopFilter, null,
                    new Handler(stopCommandThread.getLooper()));
        }
        delayReceiver = new V2rayDelayReceiver(AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN);
        IntentFilter delayFilter = new IntentFilter(
                com.github.blueboytm.flutter_v2ray.v2ray.V2rayController.ACTION_DELAY_REQUEST);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(delayReceiver, delayFilter, android.content.Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(delayReceiver, delayFilter);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // Android may recreate a killed service with a null Intent. There is no
        // recoverable configuration in that case, so do not restart the daemon.
        if (intent == null) {
            Log.w("VPN_SERVICE", "Ignoring service restart with null Intent");
            stopSelfResult(startId);
            return START_NOT_STICKY;
        }
        AppConfigs.V2RAY_SERVICE_COMMANDS startCommand =
                (AppConfigs.V2RAY_SERVICE_COMMANDS) intent.getSerializableExtra("COMMAND");
        if (startCommand == null) {
            Log.w("VPN_SERVICE", "Ignoring missing service command");
            stopSelfResult(startId);
            return START_NOT_STICKY;
        }
        if (startCommand == AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE) {
            v2rayConfig = (V2rayConfig) intent.getSerializableExtra("V2RAY_CONFIG");
            if (v2rayConfig == null) {
                Log.e(TAG, "Missing V2Ray configuration");
                stopSelfResult(startId);
                return START_NOT_STICKY;
            }
            // A foreground service MUST call startForeground() promptly,
            // before any potentially blocking native Xray initialization.
            try {
                V2rayCoreManager.showNotification(this, v2rayConfig);
            } catch (RuntimeException e) {
                Log.e("VPN_SERVICE", "Foreground promotion failed", e);
                stopSelfResult(startId);
                return START_NOT_STICKY;
            }
            // Never block the Android main thread in CoreController.startLoop().
            final V2rayConfig configToStart = v2rayConfig;
            new Thread(() -> {
                try {
                    V2rayCoreManager manager = V2rayCoreManager.getInstance();
                    manager.setUpListener(V2rayVPNService.this);
                    if (!manager.isV2rayCoreRunning() &&
                            !(configToStart.XRAY_TUN
                                    ? startXrayTun(manager, configToStart)
                                    : manager.startCore(configToStart))) {
                        Log.e("VPN_SERVICE", "Native core failed to start");
                        stopSelf();
                    }
                } catch (Exception e) {
                    Log.e("VPN_SERVICE", "Native core start failed", e);
                    stopSelf();
                }
            }, "V2Ray_CoreStartup").start();
        } else if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE)) {
            V2rayCoreManager.getInstance().stopCore();
            AppConfigs.V2RAY_CONFIG = null;
        } else if (startCommand.equals(AppConfigs.V2RAY_SERVICE_COMMANDS.MEASURE_DELAY)) {
            new Thread(() -> {
                String url = intent.getStringExtra("DELAY_URL");
                Log.i("V2RAY_DELAY", "VPN service measure delay url=" + url);
                Intent sendB = new Intent("CONNECTED_V2RAY_SERVER_DELAY");
                sendB.setPackage(getPackageName());
                sendB.putExtra("DELAY", String.valueOf(V2rayCoreManager.getInstance().getConnectedV2rayServerDelay(url)));
                sendBroadcast(sendB);
            }, "MEASURE_CONNECTED_V2RAY_SERVER_DELAY").start();
        } else {
            Log.w("VPN_SERVICE", "Unknown service command: " + startCommand);
            return START_NOT_STICKY;
        }
        return START_NOT_STICKY;
    }

    private synchronized void stopAllProcess() {
        if (stoppingAllProcesses) return;
        stoppingAllProcesses = true;
        Log.i(TAG, "Stopping VPN: closing TUN and tun2socks before native core");

        // Revoke the actual Android VPN immediately. Calling stopLoop() first
        // can block for pending native delay requests, leaving the VPN icon and
        // interface active long after the user pressed Disconnect.
        isRunning = false;
        tunProcessStarted = false;
        stopWatchingUnderlyingNetwork();
        if (process != null) {
            process.destroy();
            process = null;
        }
        if (mInterface != null) {
            try {
                mInterface.close();
            } catch (Exception e) {
                Log.w(TAG, "Failed to close TUN interface", e);
            } finally {
                mInterface = null;
            }
        }
        stopForeground(true);
        stopSelf();

        // Do not block the Android service main thread inside Go stopLoop().
        // The next session waits for DAEMON_STOPPED after cleanup completes.
        new Thread(() -> {
            try {
                V2rayCoreManager manager = V2rayCoreManager.getInstance();
                if (manager.v2rayServicesListener == V2rayVPNService.this) {
                    manager.stopCore();
                }
            } catch (Exception e) {
                Log.e(TAG, "Native core stop failed", e);
            } finally {
                Log.i(TAG, "VPN cleanup finished; reporting daemon stopped");
                com.github.blueboytm.flutter_v2ray.v2ray.V2rayConnectionCoordinator.notifyDaemonStopped(
                        getApplicationContext(),
                        com.github.blueboytm.flutter_v2ray.v2ray.V2rayConnectionCoordinator.DAEMON_VPN);
            }
        }, "V2Ray_VpnShutdown").start();
    }

    private void setup() {
        if (buildTun(true)) runTun2socks();
    }

    /**
     * Establishes the VPN interface. [excludeApps]: keep the host app (whose
     * Xray sockets would otherwise loop into the tunnel) and the blocked apps
     * out of the VPN by package. IRNet patch: Xray TUN mode passes false and
     * keeps Xray's sockets out by binding them to the physical interface
     * instead, because Samsung leaves its cloned (Dual Messenger) apps out
     * of any VPN that has an app list.
     */
    private boolean buildTun(boolean excludeApps) {
        Intent prepare_intent = prepare(this);
        if (prepare_intent != null) {
            return false;
        }
        Builder builder = new Builder();
        builder.setSession(v2rayConfig.REMARK);
        builder.setMtu(1500);
        builder.addAddress("26.26.26.1", 30);

        // Xray's Go sockets must use the underlying network rather than
        // entering our own VPN tunnel, which otherwise creates a routing loop.
        // This also excludes the host application's own traffic from the VPN.
        if (excludeApps) {
            try {
                builder.addDisallowedApplication(getPackageName());
                Log.i("VPN_SERVICE", "Excluded host package from VPN routes: " + getPackageName());
            } catch (android.content.pm.PackageManager.NameNotFoundException e) {
                Log.e("VPN_SERVICE", "Unable to exclude host app from VPN", e);
            }
        }

        if (v2rayConfig.BYPASS_SUBNETS == null || v2rayConfig.BYPASS_SUBNETS.isEmpty()) {
            builder.addRoute("0.0.0.0", 0);
        } else {
            for (String subnet : v2rayConfig.BYPASS_SUBNETS) {
                String[] parts = subnet.split("/");
                if (parts.length == 2) {
                    String address = parts[0];
                    int prefixLength = Integer.parseInt(parts[1]);
                    builder.addRoute(address, prefixLength);
                }
            }
        }
        if (excludeApps && v2rayConfig.BLOCKED_APPS != null) {
            for (int i = 0; i < v2rayConfig.BLOCKED_APPS.size(); i++) {
                try {
                    builder.addDisallowedApplication(v2rayConfig.BLOCKED_APPS.get(i));
                } catch (Exception e) {
                    //ignore
                }
            }
        }
        try {
            JSONObject json = new JSONObject(v2rayConfig.V2RAY_FULL_JSON_CONFIG);
            JSONObject dnsObject = json.getJSONObject("dns");
            JSONArray serversArray = dnsObject.getJSONArray("servers");
            for (int i = 0; i < serversArray.length(); i++) {
                String server = serversArray.getString(i);
                builder.addDnsServer(server);
            }
        } catch (JSONException e) {
            e.printStackTrace();
        }
        try {
            mInterface.close();
        } catch (Exception e) {
            //ignore
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false);
        }

        try {
            mInterface = builder.establish();
            if (mInterface == null) {
                Log.e("VPN_SERVICE", "VpnService.Builder.establish returned null");
                stopAllProcess();
                return false;
            }
            Log.i("VPN_SERVICE", "TUN established, fd=" + mInterface.getFd()
                    + ", socksPort=" + v2rayConfig.LOCAL_SOCKS5_PORT + ", appsExcluded=" + excludeApps);
            isRunning = true;
            return true;
        } catch (Exception e) {
            stopAllProcess();
            return false;
        }
    }

    // ─────────────── IRNet patch: Xray TUN mode ───────────────

    /**
     * Xray reads the VPN interface itself; its own connections are bound to
     * the physical interface (see withOutboundInterface), which keeps them
     * out of the tunnel without excluding any app.
     */
    private boolean startXrayTun(V2rayCoreManager manager, V2rayConfig config) {
        // Before the VPN is up: afterwards this app's default network is the VPN.
        outboundIface = physicalInterface();
        Log.i(TAG, "Xray TUN mode; outbound interface=" + outboundIface);
        if (!buildTun(false)) return false;
        watchUnderlyingNetwork();
        return manager.startCore(config, withOutboundInterface(config.V2RAY_FULL_JSON_CONFIG, outboundIface),
                mInterface.getFd());
    }

    /** Interface name that binds to nothing: connections fail instead of looping. */
    static final String NO_INTERFACE = "irnet-unbound";

    /**
     * The config with every outbound's connections bound to [iface] (Xray's
     * sockopt "interface", SO_BINDTODEVICE). Not the tun inbound's
     * autoOutboundsInterface: that looks interfaces up over netlink, which
     * Android refuses to apps. Without an interface the outbounds stay bound
     * to nothing, so Xray's connections fail rather than loop through the
     * tunnel.
     */
    static String withOutboundInterface(String config, String iface) {
        String name = iface == null || iface.isEmpty() ? NO_INTERFACE : iface;
        try {
            JSONObject json = new JSONObject(config);
            JSONArray outbounds = json.getJSONArray("outbounds");
            for (int i = 0; i < outbounds.length(); i++) {
                JSONObject outbound = outbounds.getJSONObject(i);
                if ("blackhole".equals(outbound.optString("protocol"))) continue;
                JSONObject stream = outbound.optJSONObject("streamSettings");
                if (stream == null) {
                    stream = new JSONObject();
                    outbound.put("streamSettings", stream);
                }
                JSONObject sockopt = stream.optJSONObject("sockopt");
                if (sockopt == null) {
                    sockopt = new JSONObject();
                    stream.put("sockopt", sockopt);
                }
                sockopt.put("interface", name);
            }
            return json.toString();
        } catch (JSONException e) {
            Log.e(TAG, "Cannot set the outbound interface", e);
            return config;
        }
    }

    /** The interface of the best network that isn't a VPN (Wi-Fi first). */
    private String physicalInterface() {
        ConnectivityManager cm = getSystemService(ConnectivityManager.class);
        if (cm == null) return null;
        Network active = cm.getActiveNetwork();
        String best = null;
        int bestScore = -1;
        for (Network n : cm.getAllNetworks()) {
            NetworkCapabilities caps = cm.getNetworkCapabilities(n);
            LinkProperties lp = cm.getLinkProperties(n);
            if (caps == null || lp == null || lp.getInterfaceName() == null) continue;
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue;
            int score = (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) ? 100 : 0)
                    + (n.equals(active) ? 50 : 0)
                    + (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ? 3
                    : caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ? 2
                    : caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ? 1 : 0);
            if (score > bestScore) {
                bestScore = score;
                best = lp.getInterfaceName();
            }
        }
        return best;
    }

    /**
     * Follows the network Android would use without the VPN; when its
     * interface changes (Wi-Fi to mobile data, ...), the core restarts bound
     * to the new one. The VPN interface and the session stay up.
     */
    private void watchUnderlyingNetwork() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return;
        ConnectivityManager cm = getSystemService(ConnectivityManager.class);
        if (cm == null) return;
        coreRestarts = Executors.newSingleThreadExecutor(r -> new Thread(r, "V2Ray_CoreRestart"));
        NetworkRequest request = new NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build();
        underlyingCallback = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onLinkPropertiesChanged(Network network, LinkProperties lp) {
                follow(network, lp.getInterfaceName());
            }
        };
        try {
            cm.registerBestMatchingNetworkCallback(request, underlyingCallback,
                    new Handler(stopCommandThread.getLooper()));
        } catch (RuntimeException e) {
            Log.w(TAG, "Cannot follow the underlying network", e);
            underlyingCallback = null;
        }
    }

    private void follow(Network network, String iface) {
        if (!isRunning || iface == null) return;
        try {
            setUnderlyingNetworks(new Network[]{network});
        } catch (RuntimeException ignored) {
        }
        if (iface.equals(outboundIface)) return;
        Log.i(TAG, "Underlying network moved to " + iface + " (was " + outboundIface + "); restarting the core");
        outboundIface = iface;
        final ExecutorService restarts = coreRestarts;
        final ParcelFileDescriptor tun = mInterface;
        final V2rayConfig config = v2rayConfig;
        if (restarts == null || tun == null || config == null) return;
        restarts.execute(() -> {
            if (!isRunning || !iface.equals(outboundIface)) return;
            V2rayCoreManager.getInstance().restartLoop(
                    withOutboundInterface(config.V2RAY_FULL_JSON_CONFIG, iface), tun.getFd());
        });
    }

    private void stopWatchingUnderlyingNetwork() {
        ConnectivityManager.NetworkCallback callback = underlyingCallback;
        underlyingCallback = null;
        if (callback != null) {
            try {
                getSystemService(ConnectivityManager.class).unregisterNetworkCallback(callback);
            } catch (RuntimeException ignored) {
            }
        }
        if (coreRestarts != null) {
            coreRestarts.shutdownNow();
            coreRestarts = null;
        }
    }

    private void runTun2socks() {
        if (tunProcessStarted) {
            Log.w(TAG, "tun2socks start already requested");
            return;
        }
        tunProcessStarted = true;

        final File executable = new File(getApplicationInfo().nativeLibraryDir, "libtun2socks.so");
        Log.i(TAG, "tun2socks executable=" + executable +
                ", exists=" + executable.exists() +
                ", executable=" + executable.canExecute() +
                ", bytes=" + executable.length());

        if (!executable.isFile() || !executable.canExecute()) {
            Log.e(TAG, "tun2socks binary is not an extracted executable");
            stopAllProcess();
            return;
        }

        ArrayList<String> cmd = new ArrayList<>(Arrays.asList(executable.getAbsolutePath(),
                "--netif-ipaddr", "26.26.26.2",
                "--netif-netmask", "255.255.255.252",
                "--socks-server-addr", "127.0.0.1:" + v2rayConfig.LOCAL_SOCKS5_PORT,
                "--tunmtu", "1500",
                "--sock-path", "sock_path",
                // IRNet patch: UDP (DNS included) through a real SOCKS5 UDP
                // ASSOCIATE. The plugin's --enable-udprelay sends datagrams to
                // the SOCKS port, which Xray stopped listening on for UDP
                // (v26.9+), so every DNS lookup in the tunnel timed out.
                "--socks5-udp",
                "--loglevel", "error"));
        try {
            ProcessBuilder pb = new ProcessBuilder(cmd);
            pb.directory(getApplicationContext().getFilesDir());
            pb.redirectErrorStream(true);
            final Process startedProcess = pb.start();
            process = startedProcess;

            // One supervisor per VPN session. Never recursively restart a rapidly
            // exiting binary: that used to create hundreds of threads in seconds.
            new Thread(() -> {
                try (BufferedReader reader = new BufferedReader(
                        new InputStreamReader(startedProcess.getInputStream()))) {
                    String line;
                    while ((line = reader.readLine()) != null) {
                        Log.i(TAG, "tun2socks: " + line);
                    }
                } catch (Exception e) {
                    Log.w(TAG, "Failed to read tun2socks output", e);
                }
            }, "Tun2socks_Output").start();

            new Thread(() -> {
                try {
                    int exitCode = startedProcess.waitFor();
                    Log.e(TAG, "tun2socks exited with code=" + exitCode);
                    if (isRunning && process == startedProcess) {
                        stopAllProcess();
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }, "Tun2socks_Wait").start();

            sendFileDescriptor();
        } catch (Exception e) {
            Log.e(TAG, "Failed to launch tun2socks", e);
            stopAllProcess();
        }
    }

    private void sendFileDescriptor() {
        final String socketPath = new File(getApplicationContext().getFilesDir(),
                "sock_path").getAbsolutePath();
        final FileDescriptor tunFd = mInterface.getFileDescriptor();
        new Thread(() -> {
            for (int attempt = 0; attempt < 20 && isRunning; attempt++) {
                try (LocalSocket socket = new LocalSocket()) {
                    socket.connect(new LocalSocketAddress(
                            socketPath, LocalSocketAddress.Namespace.FILESYSTEM));
                    socket.setFileDescriptorsForSend(new FileDescriptor[]{tunFd});
                    socket.getOutputStream().write(32);
                    socket.getOutputStream().flush();
                    socket.setFileDescriptorsForSend(null);
                    Log.i(TAG, "TUN file descriptor delivered to tun2socks");
                    return;
                } catch (Exception e) {
                    if (attempt == 19) {
                        Log.e(TAG, "Unable to send TUN fd after 20 attempts", e);
                        if (isRunning) stopAllProcess();
                        return;
                    }
                    try {
                        Thread.sleep(100);
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                }
            }
        }, "Tun2socks_SendFd").start();
    }

    @Override
    public void onDestroy() {
        // No Go stopLoop() on the Android main thread.
        stopAllProcess();
        if (delayReceiver != null) {
            unregisterReceiver(delayReceiver);
            delayReceiver = null;
        }
        if (stopCommandReceiver != null) {
            unregisterReceiver(stopCommandReceiver);
            stopCommandReceiver = null;
        }
        if (stopCommandThread != null) {
            stopCommandThread.quitSafely();
            stopCommandThread = null;
        }
        super.onDestroy();
    }

    @Override
    public void onRevoke() {
        stopAllProcess();
    }

    @Override
    public boolean onProtect(int socket) {
        return protect(socket);
    }

    @Override
    public Service getService() {
        return this;
    }

    @Override
    public void startService() {
        // Xray TUN mode set the VPN up before starting the core (and a core
        // restart must not build a second one).
        if (v2rayConfig != null && v2rayConfig.XRAY_TUN) return;
        setup();
    }

    @Override
    public void stopService() {
        stopAllProcess();
    }
}
