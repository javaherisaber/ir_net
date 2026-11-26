package com.github.blueboytm.flutter_v2ray.v2ray.utils;

import java.io.Serializable;
import java.util.ArrayList;

public class V2rayConfig implements Serializable {

    public String CONNECTED_V2RAY_SERVER_ADDRESS = "";
    public String CONNECTED_V2RAY_SERVER_PORT = "";
    public int LOCAL_SOCKS5_PORT = 10808;
    public int LOCAL_HTTP_PORT = 10809;
    public ArrayList<String> BLOCKED_APPS = null;
    public ArrayList<String> BYPASS_SUBNETS = null;
    public String V2RAY_FULL_JSON_CONFIG = null;
    public boolean ENABLE_TRAFFIC_STATICS = false;
    public String REMARK = "";
    public String APPLICATION_NAME;
    public String NOTIFICATION_DISCONNECT_BUTTON_NAME;
    public int APPLICATION_ICON;
    /**
     * IRNet patch: the config carries an Xray "tun" inbound, so Xray reads the
     * VPN interface itself (no tun2socks) and no app is excluded from the VPN
     * (see V2rayVPNService). Samsung keeps cloned (Dual Messenger) apps out of
     * any VPN that excludes or allows apps by package.
     */
    public boolean XRAY_TUN = false;
}
