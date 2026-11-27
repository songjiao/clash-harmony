package com.sjfarmltd.clashharmony;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.hardware.Camera;
import android.net.Uri;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import com.google.zxing.BarcodeFormat;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.MultiFormatReader;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.RGBLuminanceSource;
import com.google.zxing.Result;
import com.google.zxing.common.HybridBinarizer;

import java.io.InputStream;
import java.util.Collections;
import java.util.EnumMap;
import java.util.List;
import java.util.Map;

@SuppressWarnings("deprecation")
public class QrScanActivity extends Activity implements SurfaceHolder.Callback, Camera.PreviewCallback {
    public static final String EXTRA_QR_RESULT = "qr_result";
    private static final int REQ_CAMERA = 3001;
    private static final int REQ_ALBUM = 3002;

    private SurfaceView surfaceView;
    private Camera camera;
    private MultiFormatReader reader;
    private volatile boolean finished = false;
    private long lastDecodeTs = 0;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        reader = new MultiFormatReader();
        Map<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
        hints.put(DecodeHintType.POSSIBLE_FORMATS, Collections.singletonList(BarcodeFormat.QR_CODE));
        hints.put(DecodeHintType.TRY_HARDER, Boolean.TRUE);
        reader.setHints(hints);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        surfaceView = new SurfaceView(this);
        surfaceView.getHolder().addCallback(this);
        root.addView(surfaceView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        // Top overlay bar
        LinearLayout top = new LinearLayout(this);
        top.setOrientation(LinearLayout.HORIZONTAL);
        top.setGravity(Gravity.CENTER_VERTICAL);
        top.setBackgroundColor(Color.parseColor("#AA0F172A"));
        top.setPadding(dp(12), dp(10), dp(12), dp(10));

        Button btnBack = new Button(this);
        btnBack.setText("返回");
        btnBack.setTextColor(Color.WHITE);
        btnBack.setBackgroundColor(Color.parseColor("#334155"));
        btnBack.setOnClickListener(v -> finish());
        top.addView(btnBack);

        TextView title = new TextView(this);
        title.setText("扫描二维码");
        title.setTextColor(Color.WHITE);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        title.setGravity(Gravity.CENTER);
        title.setLayoutParams(new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        top.addView(title);

        Button btnAlbum = new Button(this);
        btnAlbum.setText("相册");
        btnAlbum.setTextColor(Color.WHITE);
        btnAlbum.setBackgroundColor(Color.parseColor("#0F766E"));
        btnAlbum.setOnClickListener(v -> pickFromAlbum());
        top.addView(btnAlbum);

        FrameLayout.LayoutParams topLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP);
        root.addView(top, topLp);

        TextView hint = new TextView(this);
        hint.setText("对准电脑同步二维码或订阅链接二维码（也可点右上角「相册」选图）");
        hint.setTextColor(Color.parseColor("#E2E8F0"));
        hint.setBackgroundColor(Color.parseColor("#990F172A"));
        hint.setPadding(dp(14), dp(10), dp(14), dp(10));
        hint.setGravity(Gravity.CENTER);
        FrameLayout.LayoutParams hintLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM);
        root.addView(hint, hintLp);

        setContentView(root);

        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.CAMERA}, REQ_CAMERA);
        }
    }

    private void pickFromAlbum() {
        Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
        intent.setType("image/*");
        try {
            startActivityForResult(Intent.createChooser(intent, "选择二维码图片"), REQ_ALBUM);
        } catch (Exception e) {
            Toast.makeText(this, "无法打开相册", Toast.LENGTH_SHORT).show();
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_CAMERA && grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            openCameraIfReady(surfaceView.getHolder());
        } else {
            Toast.makeText(this, "未授予相机权限，可点右上角「相册」选择二维码图片", Toast.LENGTH_LONG).show();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_ALBUM && resultCode == RESULT_OK && data != null && data.getData() != null) {
            decodeFromUri(data.getData());
        }
    }

    private void decodeFromUri(Uri uri) {
        try {
            InputStream in = getContentResolver().openInputStream(uri);
            BitmapFactory.Options opts = new BitmapFactory.Options();
            opts.inSampleSize = 1;
            Bitmap bmp = BitmapFactory.decodeStream(in, null, opts);
            if (in != null) in.close();
            if (bmp == null) {
                Toast.makeText(this, "无法解码所选图片", Toast.LENGTH_SHORT).show();
                return;
            }
            if (bmp.getWidth() > 1280 || bmp.getHeight() > 1280) {
                float scale = Math.min(1280f / bmp.getWidth(), 1280f / bmp.getHeight());
                Bitmap scaled = Bitmap.createScaledBitmap(bmp, Math.round(bmp.getWidth() * scale), Math.round(bmp.getHeight() * scale), true);
                bmp.recycle();
                bmp = scaled;
            }
            int w = bmp.getWidth();
            int h = bmp.getHeight();
            int[] pixels = new int[w * h];
            bmp.getPixels(pixels, 0, w, 0, 0, w, h);
            bmp.recycle();

            RGBLuminanceSource src = new RGBLuminanceSource(w, h, pixels);
            Result res = reader.decodeWithState(new BinaryBitmap(new HybridBinarizer(src)));
            reader.reset();
            if (res != null && res.getText() != null) {
                deliverResult(res.getText());
            }
        } catch (Exception e) {
            Toast.makeText(this, "图片中未识别到二维码", Toast.LENGTH_SHORT).show();
        }
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        openCameraIfReady(holder);
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        releaseCamera();
    }

    private void openCameraIfReady(SurfaceHolder holder) {
        if (camera != null || checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            return;
        }
        try {
            camera = Camera.open();
            if (camera == null) {
                return;
            }
            camera.setDisplayOrientation(90);
            Camera.Parameters params = camera.getParameters();
            List<String> focusModes = params.getSupportedFocusModes();
            if (focusModes != null && focusModes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE)) {
                params.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);
            }
            List<Camera.Size> sizes = params.getSupportedPreviewSizes();
            if (sizes != null) {
                Camera.Size best = null;
                for (Camera.Size s : sizes) {
                    if (s.width <= 1280 && s.height <= 960) {
                        if (best == null || (s.width * s.height > best.width * best.height)) {
                            best = s;
                        }
                    }
                }
                if (best != null) {
                    params.setPreviewSize(best.width, best.height);
                }
            }
            camera.setParameters(params);
            camera.setPreviewDisplay(holder);
            camera.setPreviewCallback(this);
            camera.startPreview();
        } catch (Exception e) {
            Toast.makeText(this, "打开相机失败: " + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    @Override
    public void onPreviewFrame(byte[] data, Camera cam) {
        if (finished || data == null) {
            return;
        }
        long now = System.currentTimeMillis();
        if (now - lastDecodeTs < 180) {
            return;
        }
        lastDecodeTs = now;
        try {
            Camera.Size size = cam.getParameters().getPreviewSize();
            PlanarYUVLuminanceSource src = new PlanarYUVLuminanceSource(
                    data, size.width, size.height, 0, 0, size.width, size.height, false);
            Result res = reader.decodeWithState(new BinaryBitmap(new HybridBinarizer(src)));
            reader.reset();
            if (res != null && res.getText() != null && !res.getText().isEmpty()) {
                deliverResult(res.getText());
            }
        } catch (Exception ignored) {
            reader.reset();
        }
    }

    private void deliverResult(String text) {
        if (finished) return;
        finished = true;
        releaseCamera();
        Intent out = new Intent();
        out.putExtra(EXTRA_QR_RESULT, text);
        setResult(RESULT_OK, out);
        finish();
    }

    private void releaseCamera() {
        if (camera != null) {
            try {
                camera.setPreviewCallback(null);
                camera.stopPreview();
                camera.release();
            } catch (Exception ignored) {
            }
            camera = null;
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        releaseCamera();
    }

    private int dp(int v) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
    }
}
