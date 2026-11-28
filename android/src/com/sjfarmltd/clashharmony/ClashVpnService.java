package com.sjfarmltd.clashharmony;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.RouteInfo;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.os.PowerManager;
import android.os.SystemClock;
import android.util.Log;

import java.io.IOException;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class ClashVpnService extends VpnService {
    private static final String TAG = "ClashHarmonyVPN";
    private static final String CHANNEL_ID = "clash_harmony_vpn";
    private static final int NOTIF_ID = 1001;
    private static final int MOBILE_TUN_MTU = 1360;

    private static final int FLAG_REBIND_TS = 1;
    private static final int FLAG_PRUNE_NON_TS = 2;

    public static final String ACTION_START = "com.sjfarmltd.clashharmony.ACTION_START_VPN";
    public static final String ACTION_STOP = "com.sjfarmltd.clashharmony.ACTION_STOP_VPN";
    public static final String ACTION_VPN_STATE = "com.sjfarmltd.clashharmony.ACTION_VPN_STATE";
    public static final String EXTRA_RUNNING = "running";
    public static final String EXTRA_ERROR = "error";

    public static volatile boolean isRunning = false;
    public static volatile String lastError = "";

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private ParcelFileDescriptor vpnInterface;

    private ConnectivityManager connectivityManager;
    private ConnectivityManager.NetworkCallback networkCallback;
    private boolean screenReceiverRegistered = false;

    private volatile Network activeUnderlyingNetwork;
    private volatile String lastIfaceName = "";
    private volatile String lastGateway = "";
    private volatile String lastTransport = "";
    private volatile boolean hasBaselineNetwork = false;
    private volatile boolean wasOffline = false;
    private volatile long screenOffAtMs = 0L;

    private final BroadcastReceiver screenStateReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            if (intent == null || intent.getAction() == null) {
                return;
            }
            String action = intent.getAction();
            if (Intent.ACTION_SCREEN_OFF.equals(action)) {
                screenOffAtMs = SystemClock.elapsedRealtime();
            } else if (Intent.ACTION_SCREEN_ON.equals(action) || Intent.ACTION_USER_PRESENT.equals(action)) {
                long offAt = screenOffAtMs;
                if (!isRunning || offAt <= 0L) {
                    return;
                }
                screenOffAtMs = 0L;
                long sleptMs = SystemClock.elapsedRealtime() - offAt;
                if (sleptMs < 30_000L) {
                    return;
                }
                final int flags = sleptMs >= 45_000L ? FLAG_REBIND_TS : 0;
                final String reason = "screen-wake-" + (sleptMs / 1000L) + "s";
                final String iface = lastIfaceName;
                final String gw = lastGateway;
                executor.execute(() -> {
                    if (!isRunning) {
                        return;
                    }
                    acquireTransientWakeLock(4000L);
                    CoreProcessManager.sendNetworkChange(iface, gw, flags, reason);
                });
            }
        }
    };

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent != null ? intent.getAction() : ACTION_START;
        if (ACTION_STOP.equals(action)) {
            executor.execute(this::stopVpnInternal);
            return START_NOT_STICKY;
        }
        startForegroundNotification("正在建立 VPN 隧道...");
        executor.execute(this::startVpnInternal);
        return START_STICKY;
    }

    private void startVpnInternal() {
        unregisterMobilityMonitors();
        closeInterface();
        lastError = "";

        if (!CoreProcessManager.ensureStarted(this)) {
            failStart("启动 Mihomo 核心进程失败");
            return;
        }

        Builder builder = new Builder();
        builder.setSession("Clash Harmony");
        builder.setMtu(MOBILE_TUN_MTU);
        builder.addAddress("198.18.0.1", 16);
        builder.addRoute("0.0.0.0", 0);
        builder.addDnsServer("198.18.0.2");
        builder.setBlocking(false);
        try {
            // Crucial: bypass VPN TUN for our own app & child libclashcore.so process
            builder.addDisallowedApplication(getPackageName());
        } catch (PackageManager.NameNotFoundException e) {
            Log.w(TAG, "addDisallowedApplication warning: " + e.getMessage());
        }

        ParcelFileDescriptor pfd = builder.establish();
        if (pfd == null) {
            failStart("系统未能创建 VPN 隧道（请先授予 VPN 权限）");
            return;
        }
        vpnInterface = pfd;

        String resp = CoreProcessManager.sendTunFd(pfd.getFileDescriptor());
        if (!"OK".equals(resp)) {
            String msg = resp.startsWith("ERR:") ? resp.substring(4) : resp;
            closeInterface();
            failStart(msg);
            return;
        }

        isRunning = true;
        lastError = "";
        registerMobilityMonitors();
        startForegroundNotification("VPN 已连接 · 漫游守护运行中");
        broadcastState(true, "");
        Log.i(TAG, "VPN started and TUN attached successfully (mtu=" + MOBILE_TUN_MTU + ")");
    }

    private void stopVpnInternal() {
        unregisterMobilityMonitors();
        CoreProcessManager.sendStopVpn();
        closeInterface();
        isRunning = false;
        lastError = "";
        broadcastState(false, "");
        try {
            stopForeground(true);
        } catch (Exception ignored) {
        }
        stopSelf();
        Log.i(TAG, "VPN stopped");
    }

    private void failStart(String err) {
        unregisterMobilityMonitors();
        isRunning = false;
        lastError = err != null ? err : "VPN 启动失败";
        broadcastState(false, lastError);
        try {
            stopForeground(true);
        } catch (Exception ignored) {
        }
        stopSelf();
    }

    private void registerMobilityMonitors() {
        hasBaselineNetwork = false;
        wasOffline = false;
        activeUnderlyingNetwork = null;
        lastIfaceName = "";
        lastGateway = "";
        lastTransport = "";
        screenOffAtMs = 0L;

        connectivityManager = (ConnectivityManager) getSystemService(CONNECTIVITY_SERVICE);
        if (connectivityManager != null) {
            networkCallback = new ConnectivityManager.NetworkCallback() {
                @Override
                public void onAvailable(Network network) {
                    executor.execute(() -> handleNetworkEvent(network, null, null, "available"));
                }

                @Override
                public void onLinkPropertiesChanged(Network network, LinkProperties linkProperties) {
                    executor.execute(() -> handleNetworkEvent(network, linkProperties, null, "link-props"));
                }

                @Override
                public void onCapabilitiesChanged(Network network, NetworkCapabilities networkCapabilities) {
                    executor.execute(() -> handleNetworkEvent(network, null, networkCapabilities, "capabilities"));
                }

                @Override
                public void onLost(Network network) {
                    executor.execute(() -> handleNetworkLost(network));
                }
            };
            try {
                connectivityManager.registerDefaultNetworkCallback(networkCallback);
                Network active = connectivityManager.getActiveNetwork();
                if (active != null) {
                    handleNetworkEvent(active, null, null, "initial");
                }
                Log.i(TAG, "Registered Android default NetworkCallback for seamless roaming");
            } catch (Exception e) {
                Log.w(TAG, "registerDefaultNetworkCallback failed: " + e.getMessage());
                networkCallback = null;
            }
        }

        if (!screenReceiverRegistered) {
            try {
                IntentFilter filter = new IntentFilter();
                filter.addAction(Intent.ACTION_SCREEN_OFF);
                filter.addAction(Intent.ACTION_SCREEN_ON);
                filter.addAction(Intent.ACTION_USER_PRESENT);
                registerReceiver(screenStateReceiver, filter);
                screenReceiverRegistered = true;
            } catch (Exception e) {
                Log.w(TAG, "registerReceiver(screen) failed: " + e.getMessage());
            }
        }
    }

    private void unregisterMobilityMonitors() {
        if (connectivityManager != null && networkCallback != null) {
            try {
                connectivityManager.unregisterNetworkCallback(networkCallback);
            } catch (Exception ignored) {
            }
            networkCallback = null;
        }
        if (screenReceiverRegistered) {
            try {
                unregisterReceiver(screenStateReceiver);
            } catch (Exception ignored) {
            }
            screenReceiverRegistered = false;
        }
        activeUnderlyingNetwork = null;
        hasBaselineNetwork = false;
        wasOffline = false;
        screenOffAtMs = 0L;
    }

    private void handleNetworkEvent(Network network, LinkProperties lpArg, NetworkCapabilities capsArg, String trigger) {
        if (!isRunning || network == null || connectivityManager == null) {
            return;
        }
        NetworkCapabilities caps = capsArg != null ? capsArg : connectivityManager.getNetworkCapabilities(network);
        if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
            return;
        }
        LinkProperties lp = lpArg != null ? lpArg : connectivityManager.getLinkProperties(network);
        if (lp == null) {
            return;
        }
        String ifaceName = lp.getInterfaceName();
        if (ifaceName == null) {
            ifaceName = "";
        }
        ifaceName = ifaceName.trim();
        if (ifaceName.isEmpty() || ifaceName.startsWith("tun") || ifaceName.startsWith("vpn")) {
            return;
        }
        String gateway = extractDefaultIPv4Gateway(lp);
        String transport = describeTransport(caps);

        if (!hasBaselineNetwork) {
            hasBaselineNetwork = true;
            wasOffline = false;
            activeUnderlyingNetwork = network;
            lastIfaceName = ifaceName;
            lastGateway = gateway;
            lastTransport = transport;
            CoreProcessManager.sendNetworkChange(ifaceName, gateway, 0, "baseline-" + transport);
            return;
        }

        boolean changed = wasOffline
                || !ifaceName.equals(lastIfaceName)
                || (!gateway.isEmpty() && !gateway.equals(lastGateway))
                || (!transport.isEmpty() && !transport.equals(lastTransport));
        if (!changed) {
            activeUnderlyingNetwork = network;
            return;
        }

        String reason;
        if (wasOffline) {
            reason = "recover-" + transport;
        } else if (!transport.equals(lastTransport) && !lastTransport.isEmpty()) {
            reason = "switch-" + lastTransport + "-to-" + transport;
        } else if (!ifaceName.equals(lastIfaceName)) {
            reason = "iface-" + lastIfaceName + "-to-" + ifaceName;
        } else {
            reason = "route-" + transport + "-" + trigger;
        }

        activeUnderlyingNetwork = network;
        lastIfaceName = ifaceName;
        lastGateway = gateway;
        lastTransport = transport;
        wasOffline = false;

        acquireTransientWakeLock(5000L);
        CoreProcessManager.sendNetworkChange(ifaceName, gateway, FLAG_REBIND_TS | FLAG_PRUNE_NON_TS, reason);
    }

    private void handleNetworkLost(Network network) {
        if (!isRunning || network == null) {
            return;
        }
        if (activeUnderlyingNetwork != null && !activeUnderlyingNetwork.equals(network)) {
            return;
        }
        wasOffline = true;
        activeUnderlyingNetwork = null;
        CoreProcessManager.sendNetworkChange("", "", 0, "net-lost");
    }

    private String extractDefaultIPv4Gateway(LinkProperties lp) {
        if (lp == null) {
            return "";
        }
        try {
            for (RouteInfo route : lp.getRoutes()) {
                if (route == null || !route.isDefaultRoute()) {
                    continue;
                }
                InetAddress gw = route.getGateway();
                if (gw instanceof Inet4Address && !gw.isAnyLocalAddress()) {
                    String host = gw.getHostAddress();
                    if (host != null && !host.isEmpty()) {
                        return host;
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return "";
    }

    private String describeTransport(NetworkCapabilities caps) {
        if (caps == null) {
            return "net";
        }
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            return "wifi";
        }
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
            return "cellular";
        }
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
            return "ethernet";
        }
        return "other";
    }

    private void acquireTransientWakeLock(long timeoutMs) {
        try {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            if (pm != null) {
                PowerManager.WakeLock wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ClashHarmony:NetRebind");
                wl.setReferenceCounted(false);
                wl.acquire(timeoutMs);
            }
        } catch (Exception e) {
            Log.w(TAG, "acquireTransientWakeLock ignored: " + e.getMessage());
        }
    }

    private void closeInterface() {
        if (vpnInterface != null) {
            try {
                vpnInterface.close();
            } catch (IOException ignored) {
            }
            vpnInterface = null;
        }
    }

    private void broadcastState(boolean running, String error) {
        Intent i = new Intent(ACTION_VPN_STATE);
        i.setPackage(getPackageName());
        i.putExtra(EXTRA_RUNNING, running);
        i.putExtra(EXTRA_ERROR, error);
        sendBroadcast(i);
    }

    private void startForegroundNotification(String contentText) {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm != null) {
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL_ID,
                    "Clash Harmony VPN",
                    NotificationManager.IMPORTANCE_LOW
            );
            ch.setDescription("Clash Harmony (Mihomo + Tailscale) VPN 运行状态");
            nm.createNotificationChannel(ch);
        }

        int piFlags = PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE;
        Intent openIntent = new Intent(this, MainActivity.class);
        openIntent.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
        PendingIntent openPi = PendingIntent.getActivity(this, 0, openIntent, piFlags);

        Intent stopIntent = new Intent(this, ClashVpnService.class);
        stopIntent.setAction(ACTION_STOP);
        PendingIntent stopPi = PendingIntent.getService(this, 1, stopIntent, piFlags);

        Notification.Builder nb = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        nb.setContentTitle("Clash Harmony")
                .setContentText(contentText)
                .setSmallIcon(android.R.drawable.ic_lock_lock)
                .setOngoing(true)
                .setContentIntent(openPi)
                .addAction(new Notification.Action.Builder(null, "断开", stopPi).build());

        startForeground(NOTIF_ID, nb.build());
    }

    @Override
    public void onRevoke() {
        executor.execute(this::stopVpnInternal);
        super.onRevoke();
    }

    @Override
    public void onDestroy() {
        executor.execute(() -> {
            unregisterMobilityMonitors();
            closeInterface();
        });
        super.onDestroy();
    }
}
