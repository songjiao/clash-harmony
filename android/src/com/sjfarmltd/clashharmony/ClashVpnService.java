package com.sjfarmltd.clashharmony;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import java.io.IOException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class ClashVpnService extends VpnService {
    private static final String TAG = "ClashHarmonyVPN";
    private static final String CHANNEL_ID = "clash_harmony_vpn";
    private static final int NOTIF_ID = 1001;

    public static final String ACTION_START = "com.sjfarmltd.clashharmony.ACTION_START_VPN";
    public static final String ACTION_STOP = "com.sjfarmltd.clashharmony.ACTION_STOP_VPN";
    public static final String ACTION_VPN_STATE = "com.sjfarmltd.clashharmony.ACTION_VPN_STATE";
    public static final String EXTRA_RUNNING = "running";
    public static final String EXTRA_ERROR = "error";

    public static volatile boolean isRunning = false;
    public static volatile String lastError = "";

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private ParcelFileDescriptor vpnInterface;

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
        closeInterface();
        lastError = "";

        if (!CoreProcessManager.ensureStarted(this)) {
            failStart("启动 Mihomo 核心进程失败");
            return;
        }

        Builder builder = new Builder();
        builder.setSession("Clash Harmony");
        builder.setMtu(1500);
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
        startForegroundNotification("VPN 已连接 · Mihomo + Tailscale 运行中");
        broadcastState(true, "");
        Log.i(TAG, "VPN started and TUN attached successfully");
    }

    private void stopVpnInternal() {
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
        isRunning = false;
        lastError = err != null ? err : "VPN 启动失败";
        broadcastState(false, lastError);
        try {
            stopForeground(true);
        } catch (Exception ignored) {
        }
        stopSelf();
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
        executor.execute(this::closeInterface);
        super.onDestroy();
    }
}
