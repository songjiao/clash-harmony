package com.sjfarmltd.clashharmony;

import android.content.Context;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.Process;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public final class CoreProcessManager {
    private static final String TAG = "ClashHarmonyCore";
    public static final String UI_ADDR = "127.0.0.1:9091";
    public static final String UI_URL = "http://" + UI_ADDR;

    private static final Object LOCK = new Object();
    private static java.lang.Process coreProc;
    private static String activeSocketName = "";

    private CoreProcessManager() {}

    public static String getTunSocketName() {
        return "clash_harmony_tun_" + Process.myUid();
    }

    public static boolean ensureStarted(Context context) {
        synchronized (LOCK) {
            if (isAliveLocked() && isHttpListening()) {
                return true;
            }
            stopLocked();

            File filesDir = context.getFilesDir();
            File runtimeDir = new File(filesDir, "runtime");
            if (!runtimeDir.exists()) {
                runtimeDir.mkdirs();
            }
            extractGeoipAsset(context, new File(runtimeDir, "geoip.metadb"));

            File binFile = new File(context.getApplicationInfo().nativeLibraryDir, "libclashcore.so");
            if (!binFile.exists()) {
                Log.e(TAG, "Core binary missing at " + binFile.getAbsolutePath());
                return false;
            }
            if (!binFile.canExecute()) {
                binFile.setExecutable(true, false);
            }

            activeSocketName = getTunSocketName();
            File logFile = new File(runtimeDir, "android-core.log");

            try {
                ProcessBuilder pb = new ProcessBuilder(
                        binFile.getAbsolutePath(),
                        "-data", filesDir.getAbsolutePath(),
                        "-ui", UI_ADDR,
                        "-headless",
                        "-no-browser",
                        "-tun-socket", activeSocketName
                );
                pb.directory(filesDir);
                pb.redirectErrorStream(true);
                pb.redirectOutput(ProcessBuilder.Redirect.to(logFile));
                coreProc = pb.start();
                Log.i(TAG, "Started libclashcore.so with tun-socket=" + activeSocketName);
            } catch (IOException e) {
                Log.e(TAG, "Failed to start libclashcore.so", e);
                return false;
            }
        }
        return waitForHttpReady(8000);
    }

    public static boolean isHttpListening() {
        HttpURLConnection conn = null;
        try {
            URL url = new URL(UI_URL + "/api/state");
            conn = (HttpURLConnection) url.openConnection();
            conn.setConnectTimeout(600);
            conn.setReadTimeout(800);
            conn.setRequestMethod("GET");
            int code = conn.getResponseCode();
            return code >= 200 && code < 500;
        } catch (Exception ignored) {
            return false;
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }
    }

    public static boolean waitForHttpReady(long timeoutMs) {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (isHttpListening()) {
                return true;
            }
            try {
                Thread.sleep(150);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return false;
            }
        }
        return false;
    }

    public static String sendTunFd(FileDescriptor fd) {
        String sockName = activeSocketName.isEmpty() ? getTunSocketName() : activeSocketName;
        for (int attempt = 0; attempt < 10; attempt++) {
            LocalSocket socket = new LocalSocket();
            try {
                socket.connect(new LocalSocketAddress(sockName, LocalSocketAddress.Namespace.ABSTRACT));
                socket.setSoTimeout(15000);
                socket.setFileDescriptorsForSend(new FileDescriptor[]{fd});
                OutputStream os = socket.getOutputStream();
                os.write("START\n".getBytes(StandardCharsets.UTF_8));
                os.flush();

                BufferedReader br = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                String resp = br.readLine();
                return resp == null ? "ERR:empty response" : resp.trim();
            } catch (IOException e) {
                Log.w(TAG, "sendTunFd attempt " + attempt + " failed: " + e.getMessage());
                try {
                    Thread.sleep(200);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    return "ERR:interrupted";
                }
            } finally {
                try {
                    socket.close();
                } catch (IOException ignored) {
                }
            }
        }
        return "ERR:无法连接核心 TUN 控制通道";
    }

    public static void sendNetworkChange(String ifaceName, String gateway, int flags, String reason) {
        String sockName = activeSocketName.isEmpty() ? getTunSocketName() : activeSocketName;
        String safeIface = sanitizeField(ifaceName);
        String safeGw = sanitizeField(gateway);
        String safeReason = sanitizeField(reason);
        if (safeReason.isEmpty()) {
            safeReason = "android-netchange";
        }
        String payload = "NETCHANGE|" + safeIface + "|" + safeGw + "|" + flags + "|" + safeReason + "\n";

        LocalSocket socket = new LocalSocket();
        try {
            socket.connect(new LocalSocketAddress(sockName, LocalSocketAddress.Namespace.ABSTRACT));
            socket.setSoTimeout(3000);
            OutputStream os = socket.getOutputStream();
            os.write(payload.getBytes(StandardCharsets.UTF_8));
            os.flush();
            BufferedReader br = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
            String resp = br.readLine();
            Log.i(TAG, "sendNetworkChange(" + safeReason + ", iface=" + safeIface + ", gw=" + safeGw + ", flags=" + flags + ") -> " + resp);
        } catch (IOException e) {
            Log.w(TAG, "sendNetworkChange ignored: " + e.getMessage());
        } finally {
            try {
                socket.close();
            } catch (IOException ignored) {
            }
        }
    }

    private static String sanitizeField(String value) {
        if (value == null) {
            return "";
        }
        return value.replace("|", "_").replace("\r", "").replace("\n", "").trim();
    }

    public static void sendStopVpn() {
        String sockName = activeSocketName.isEmpty() ? getTunSocketName() : activeSocketName;
        LocalSocket socket = new LocalSocket();
        try {
            socket.connect(new LocalSocketAddress(sockName, LocalSocketAddress.Namespace.ABSTRACT));
            socket.setSoTimeout(5000);
            OutputStream os = socket.getOutputStream();
            os.write("STOP\n".getBytes(StandardCharsets.UTF_8));
            os.flush();
            BufferedReader br = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
            br.readLine();
        } catch (IOException e) {
            Log.w(TAG, "sendStopVpn ignored: " + e.getMessage());
        } finally {
            try {
                socket.close();
            } catch (IOException ignored) {
            }
        }
    }

    private static boolean isAliveLocked() {
        if (coreProc == null) {
            return false;
        }
        try {
            coreProc.exitValue();
            return false;
        } catch (IllegalThreadStateException running) {
            return true;
        }
    }

    private static void stopLocked() {
        if (coreProc != null) {
            try {
                coreProc.destroy();
            } catch (Exception ignored) {
            }
            coreProc = null;
        }
    }

    private static void extractGeoipAsset(Context context, File dst) {
        try {
            if (dst.exists() && dst.length() > 1024 * 1024) {
                return;
            }
            InputStream in = context.getAssets().open("geoip.metadb");
            File tmp = new File(dst.getAbsolutePath() + ".tmp");
            FileOutputStream out = new FileOutputStream(tmp);
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
            out.flush();
            out.close();
            in.close();
            if (!tmp.renameTo(dst)) {
                tmp.delete();
            }
            Log.i(TAG, "Extracted geoip.metadb (" + dst.length() + " bytes)");
        } catch (Exception e) {
            Log.w(TAG, "extractGeoipAsset warning: " + e.getMessage());
        }
    }
}
