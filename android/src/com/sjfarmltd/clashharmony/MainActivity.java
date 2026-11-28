package com.sjfarmltd.clashharmony;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.net.VpnService;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.Window;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONObject;

public class MainActivity extends Activity {
    private static final int REQ_VPN_PREPARE = 2001;
    private static final int REQ_QR_SCAN = 2002;
    private static final int REQ_FILE_CHOOSER = 2003;
    private static final int REQ_POST_NOTIF = 2004;

    private WebView webView;
    private TextView statusDot;
    private TextView statusText;
    private Button btnVpnToggle;
    private Button btnKeepAlive;
    private String pendingQrMode = "sync";
    private ValueCallback<Uri[]> fileChooserCallback;
    private long pausedAtMs = 0L;

    private final BroadcastReceiver vpnReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            boolean running = intent.getBooleanExtra(ClashVpnService.EXTRA_RUNNING, false);
            String err = intent.getStringExtra(ClashVpnService.EXTRA_ERROR);
            updateVpnBar(running);
            if (err != null && !err.isEmpty()) {
                Toast.makeText(MainActivity.this, err, Toast.LENGTH_LONG).show();
            }
            if (webView != null) {
                webView.evaluateJavascript("if (window.loadState) { loadState(); loadTailscaleStatus(); }", null);
            }
        }
    };

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        Window win = getWindow();
        if (win != null) {
            win.setStatusBarColor(Color.parseColor("#0F172A"));
            win.setNavigationBarColor(Color.parseColor("#0B1120"));
        }

        if (Build.VERSION.SDK_INT >= 33) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_POST_NOTIF);
            }
        }

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.parseColor("#0B1120"));

        // Native dark-navy top control bar
        LinearLayout topBar = new LinearLayout(this);
        topBar.setOrientation(LinearLayout.HORIZONTAL);
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        topBar.setBackgroundColor(Color.parseColor("#0F172A"));
        topBar.setPadding(dp(12), dp(8), dp(12), dp(8));

        LinearLayout titleCol = new LinearLayout(this);
        titleCol.setOrientation(LinearLayout.VERTICAL);
        LinearLayout.LayoutParams titleLp = new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        titleCol.setLayoutParams(titleLp);

        TextView titleView = new TextView(this);
        titleView.setText("Clash Harmony");
        titleView.setTextColor(Color.parseColor("#F8FAFC"));
        titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        titleView.setTypeface(null, android.graphics.Typeface.BOLD);

        LinearLayout subRow = new LinearLayout(this);
        subRow.setOrientation(LinearLayout.HORIZONTAL);
        subRow.setGravity(Gravity.CENTER_VERTICAL);

        statusDot = new TextView(this);
        statusDot.setText("● ");
        statusDot.setTextSize(TypedValue.COMPLEX_UNIT_SP, 10);
        statusDot.setTextColor(Color.parseColor("#94A3B8"));

        statusText = new TextView(this);
        statusText.setText("初始化核心...");
        statusText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        statusText.setTextColor(Color.parseColor("#94A3B8"));

        subRow.addView(statusDot);
        subRow.addView(statusText);
        titleCol.addView(titleView);
        titleCol.addView(subRow);
        topBar.addView(titleCol);

        btnKeepAlive = makePillButton("保活", "#334155", "#FCD34D");
        btnKeepAlive.setOnClickListener(v -> requestIgnoreBatteryOptimizations());
        LinearLayout.LayoutParams keepLp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(34));
        keepLp.rightMargin = dp(6);
        btnKeepAlive.setLayoutParams(keepLp);
        topBar.addView(btnKeepAlive);

        Button btnScan = makePillButton("扫码同步", "#1E293B", "#7DD3FC");
        btnScan.setOnClickListener(v -> launchQrScanner("sync"));
        LinearLayout.LayoutParams scanLp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(34));
        scanLp.rightMargin = dp(6);
        btnScan.setLayoutParams(scanLp);
        topBar.addView(btnScan);

        btnVpnToggle = makePillButton("开启 VPN", "#10B981", "#052E16");
        btnVpnToggle.setTypeface(null, android.graphics.Typeface.BOLD);
        btnVpnToggle.setOnClickListener(v -> toggleVpn());
        LinearLayout.LayoutParams vpnLp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(34));
        btnVpnToggle.setLayoutParams(vpnLp);
        topBar.addView(btnVpnToggle);

        root.addView(topBar, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));

        View divider = new View(this);
        divider.setBackgroundColor(Color.parseColor("#263348"));
        root.addView(divider, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(1)));

        // Full-screen WebView rendering the embedded Clash Harmony Web Console
        webView = new WebView(this);
        webView.setBackgroundColor(Color.parseColor("#0B1120"));
        WebSettings ws = webView.getSettings();
        ws.setJavaScriptEnabled(true);
        ws.setDomStorageEnabled(true);
        ws.setCacheMode(WebSettings.LOAD_NO_CACHE);
        ws.setAllowFileAccess(true);
        webView.addJavascriptInterface(new AndroidBridge(), "AndroidBridge");

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                if (uri != null && uri.getHost() != null && !uri.getHost().equals("127.0.0.1") && !uri.getHost().equals("localhost")) {
                    openInExternalBrowser(uri.toString());
                    return true;
                }
                return false;
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView webView, ValueCallback<Uri[]> filePathCallback, FileChooserParams fileChooserParams) {
                if (fileChooserCallback != null) {
                    fileChooserCallback.onReceiveValue(null);
                }
                fileChooserCallback = filePathCallback;
                Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
                intent.addCategory(Intent.CATEGORY_OPENABLE);
                intent.setType("*/*");
                try {
                    startActivityForResult(Intent.createChooser(intent, "选择配置文件"), REQ_FILE_CHOOSER);
                } catch (Exception e) {
                    fileChooserCallback = null;
                    return false;
                }
                return true;
            }
        });

        root.addView(webView, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(root);

        IntentFilter filter = new IntentFilter(ClashVpnService.ACTION_VPN_STATE);
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(vpnReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(vpnReceiver, filter);
        }

        updateVpnBar(ClashVpnService.isRunning);
        updateKeepAliveButton();
        bootCoreAndLoadUi();
    }

    @Override
    protected void onPause() {
        pausedAtMs = SystemClock.elapsedRealtime();
        super.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        updateVpnBar(ClashVpnService.isRunning);
        updateKeepAliveButton();
        long pausedAt = pausedAtMs;
        pausedAtMs = 0L;
        if (ClashVpnService.isRunning && pausedAt > 0L) {
            long awayMs = SystemClock.elapsedRealtime() - pausedAt;
            if (awayMs >= 30_000L) {
                final int flags = awayMs >= 45_000L ? 1 : 0;
                final String reason = "app-resume-" + (awayMs / 1000L) + "s";
                new Thread(() -> CoreProcessManager.sendNetworkChange("", "", flags, reason)).start();
            }
        }
    }

    private boolean isIgnoringBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true;
        }
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        return pm != null && pm.isIgnoringBatteryOptimizations(getPackageName());
    }

    private void updateKeepAliveButton() {
        if (btnKeepAlive == null) {
            return;
        }
        btnKeepAlive.setVisibility(isIgnoringBatteryOptimizations() ? View.GONE : View.VISIBLE);
    }

    @SuppressLint("BatteryLife")
    private void requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return;
        }
        if (isIgnoringBatteryOptimizations()) {
            Toast.makeText(this, "已加入电池优化白名单", Toast.LENGTH_SHORT).show();
            updateKeepAliveButton();
            return;
        }
        try {
            Intent intent = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            intent.setData(Uri.parse("package:" + getPackageName()));
            startActivity(intent);
        } catch (Exception e) {
            try {
                startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
            } catch (Exception ignored) {
                Toast.makeText(this, "请在系统设置中允许 Clash Harmony 后台高耗电/忽略电池优化", Toast.LENGTH_LONG).show();
            }
        }
    }

    private void bootCoreAndLoadUi() {
        new Thread(() -> {
            boolean ok = CoreProcessManager.ensureStarted(getApplicationContext());
            runOnUiThread(() -> {
                updateVpnBar(ClashVpnService.isRunning);
                if (ok) {
                    webView.loadUrl(CoreProcessManager.UI_URL);
                } else {
                    statusText.setText("核心启动失败");
                    Toast.makeText(MainActivity.this, "Mihomo 核心进程启动失败，请查看 android-core.log", Toast.LENGTH_LONG).show();
                }
            });
        }).start();
    }

    private void toggleVpn() {
        if (ClashVpnService.isRunning) {
            Intent stopIntent = new Intent(this, ClashVpnService.class);
            stopIntent.setAction(ClashVpnService.ACTION_STOP);
            startService(stopIntent);
            updateVpnBar(false);
            return;
        }
        Intent prep = VpnService.prepare(this);
        if (prep != null) {
            startActivityForResult(prep, REQ_VPN_PREPARE);
        } else {
            startVpnServiceNow();
        }
    }

    private void startVpnServiceNow() {
        statusText.setText("正在启动 VPN...");
        Intent startIntent = new Intent(this, ClashVpnService.class);
        startIntent.setAction(ClashVpnService.ACTION_START);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(startIntent);
        } else {
            startService(startIntent);
        }
    }

    private void launchQrScanner(String mode) {
        pendingQrMode = (mode != null && !mode.isEmpty()) ? mode : "sync";
        Intent i = new Intent(this, QrScanActivity.class);
        startActivityForResult(i, REQ_QR_SCAN);
    }

    private void updateVpnBar(boolean running) {
        if (running) {
            statusDot.setTextColor(Color.parseColor("#10B981"));
            statusText.setText("VPN 运行中 · Android TUN");
            statusText.setTextColor(Color.parseColor("#6EE7B7"));
            btnVpnToggle.setText("断开 VPN");
            stylePillButton(btnVpnToggle, "#7F1D1D", "#FCA5A5");
        } else {
            statusDot.setTextColor(Color.parseColor("#94A3B8"));
            statusText.setText("VPN 未连接");
            statusText.setTextColor(Color.parseColor("#94A3B8"));
            btnVpnToggle.setText("开启 VPN");
            stylePillButton(btnVpnToggle, "#10B981", "#052E16");
        }
    }

    private void openInExternalBrowser(String url) {
        try {
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(intent);
        } catch (Exception e) {
            Toast.makeText(this, "无法打开浏览器: " + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_VPN_PREPARE) {
            if (resultCode == RESULT_OK) {
                startVpnServiceNow();
            } else {
                Toast.makeText(this, "未授予 VPN 权限，无法启动全局代理", Toast.LENGTH_SHORT).show();
            }
        } else if (requestCode == REQ_QR_SCAN && resultCode == RESULT_OK && data != null) {
            String qrText = data.getStringExtra(QrScanActivity.EXTRA_QR_RESULT);
            if (qrText != null && !qrText.trim().isEmpty() && webView != null) {
                String js = "if (window.onAndroidQrResult) { window.onAndroidQrResult("
                        + JSONObject.quote(pendingQrMode) + ", " + JSONObject.quote(qrText) + "); }";
                webView.evaluateJavascript(js, null);
            }
        } else if (requestCode == REQ_FILE_CHOOSER) {
            if (fileChooserCallback != null) {
                Uri[] results = null;
                if (resultCode == RESULT_OK && data != null && data.getData() != null) {
                    results = new Uri[]{data.getData()};
                }
                fileChooserCallback.onReceiveValue(results);
                fileChooserCallback = null;
            }
        }
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }

    @Override
    protected void onDestroy() {
        try {
            unregisterReceiver(vpnReceiver);
        } catch (Exception ignored) {
        }
        super.onDestroy();
    }

    private Button makePillButton(String text, String bgHex, String textHex) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        b.setPadding(dp(12), 0, dp(12), 0);
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        stylePillButton(b, bgHex, textHex);
        return b;
    }

    private void stylePillButton(Button b, String bgHex, String textHex) {
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(Color.parseColor(bgHex));
        gd.setCornerRadius(dp(8));
        b.setBackground(gd);
        b.setTextColor(Color.parseColor(textHex));
    }

    private int dp(int v) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
    }

    private final class AndroidBridge {
        @JavascriptInterface
        public void scanQr(String mode) {
            runOnUiThread(() -> launchQrScanner(mode));
        }

        @JavascriptInterface
        public void toggleVpn() {
            runOnUiThread(MainActivity.this::toggleVpn);
        }

        @JavascriptInterface
        public void openExternalUrl(String url) {
            runOnUiThread(() -> openInExternalBrowser(url));
        }

        @JavascriptInterface
        public boolean isBatteryOptimizationIgnored() {
            return isIgnoringBatteryOptimizations();
        }

        @JavascriptInterface
        public void requestBatteryOptimizationIgnore() {
            runOnUiThread(MainActivity.this::requestIgnoreBatteryOptimizations);
        }

        @JavascriptInterface
        public void copyText(String text) {
            runOnUiThread(() -> {
                ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
                if (cm != null) {
                    cm.setPrimaryClip(ClipData.newPlainText("ClashHarmony", text));
                    Toast.makeText(MainActivity.this, "已复制到剪贴板", Toast.LENGTH_SHORT).show();
                }
            });
        }
    }
}
