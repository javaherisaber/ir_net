package com.github.blueboytm.flutter_v2ray.v2ray.core;

import android.content.Context;
import android.net.ConnectivityManager;
import android.os.Build;
import android.system.OsConstants;

import java.net.InetAddress;
import java.net.InetSocketAddress;

import libv2ray.ProcessFinder;

/**
 * IRNet patch: tells Xray which app owns a connection coming in through its
 * TUN inbound, for routing rules on "process". Answers the app id (the uid
 * without its user part), so an app and its Samsung clone (Dual Messenger,
 * another user) match the same rule.
 */
public final class AppProcessFinder implements ProcessFinder {
    private static final int PER_USER_RANGE = 100000;
    private final ConnectivityManager connectivity;

    public AppProcessFinder(Context context) {
        connectivity = context.getSystemService(ConnectivityManager.class);
    }

    @Override
    public long findProcessByConnection(String network, String srcIP, long srcPort, String destIP, long destPort) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || connectivity == null) return -1;
        try {
            int protocol = "udp".equals(network) ? OsConstants.IPPROTO_UDP : OsConstants.IPPROTO_TCP;
            // IP literals only: no lookups here.
            InetSocketAddress local = new InetSocketAddress(InetAddress.getByName(srcIP), (int) srcPort);
            InetSocketAddress remote = new InetSocketAddress(InetAddress.getByName(destIP), (int) destPort);
            int uid = connectivity.getConnectionOwnerUid(protocol, local, remote);
            return uid < 0 ? -1 : uid % PER_USER_RANGE;
        } catch (Exception e) {
            return -1;
        }
    }
}
