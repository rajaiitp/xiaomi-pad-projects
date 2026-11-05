package local.hdmi.touchcontroller;

import android.app.Activity;
import android.graphics.Color;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.ByteBuffer;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public final class TouchControllerActivity extends Activity {
    private static final int VIDEO_WIDTH = 1280;
    private static final int VIDEO_HEIGHT = 672;
    private static final byte[] END = new byte[0];
    private static final String RECORDER_PID_FILE =
            "/data/local/tmp/tv-touch-controller-screenrecord.pid";

    private final BlockingQueue<byte[]> nalQueue = new ArrayBlockingQueue<>(30);
    private final ExecutorService inputExecutor = Executors.newSingleThreadExecutor();
    private SurfaceView videoView;
    private TextView statusView;
    private Process recorderProcess;
    private MediaCodec decoder;
    private volatile boolean stopping;
    private boolean sessionStarted;
    private int displayId = -1;
    private String physicalDisplayId;
    private int remoteWidth = 4096;
    private int remoteHeight = 2160;
    private float downX;
    private float downY;
    private long downTime;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().setStatusBarColor(Color.BLACK);
        getWindow().setNavigationBarColor(Color.BLACK);
        getWindow()
                .getDecorView()
                .setSystemUiVisibility(
                        View.SYSTEM_UI_FLAG_FULLSCREEN
                                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                                | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        videoView = new SurfaceView(this);
        root.addView(
                videoView,
                new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT));

        statusView = new TextView(this);
        statusView.setText("Connecting to HDMI display…");
        statusView.setTextColor(Color.WHITE);
        statusView.setTextSize(18);
        statusView.setGravity(Gravity.CENTER);
        root.addView(
                statusView,
                new FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.MATCH_PARENT,
                        FrameLayout.LayoutParams.MATCH_PARENT));

        Button close = new Button(this);
        close.setText("×");
        close.setTextSize(26);
        close.setTextColor(Color.WHITE);
        close.setPadding(0, 0, 0, 0);
        close.setMinWidth(0);
        close.setMinHeight(0);
        close.setBackgroundResource(R.drawable.close_button);
        close.setContentDescription("Close TV touch control");
        close.setOnClickListener(
                new View.OnClickListener() {
                    @Override
                    public void onClick(View view) {
                        finish();
                    }
                });
        FrameLayout.LayoutParams closeParams = new FrameLayout.LayoutParams(dp(44), dp(44));
        closeParams.gravity = Gravity.BOTTOM | Gravity.START;
        closeParams.setMargins(dp(12), dp(12), dp(12), dp(12));
        root.addView(close, closeParams);
        setContentView(root);

        videoView.setOnTouchListener(
                new View.OnTouchListener() {
                    @Override
                    public boolean onTouch(View view, MotionEvent event) {
                        return handleTouch(event);
                    }
                });
        videoView
                .getHolder()
                .addCallback(
                        new SurfaceHolder.Callback() {
                            @Override
                            public void surfaceCreated(SurfaceHolder holder) {
                                beginSession(holder.getSurface());
                            }

                            @Override
                            public void surfaceChanged(
                                    SurfaceHolder holder, int format, int width, int height) {}

                            @Override
                            public void surfaceDestroyed(SurfaceHolder holder) {
                                stopSession();
                            }
                        });
    }

    private synchronized void beginSession(final Surface surface) {
        if (sessionStarted) return;
        sessionStarted = true;
        stopping = false;
        nalQueue.clear();
        new Thread(
                        new Runnable() {
                            @Override
                            public void run() {
                                try {
                                    stopRecordedProcess();
                                    displayId =
                                            Integer.parseInt(
                                                    rootOutput(
                                                                    "cmd display get-displays"
                                                                        + " --type external -i |"
                                                                        + " head -1")
                                                            .trim());
                                    physicalDisplayId =
                                            rootOutput(
                                                            "dumpsys SurfaceFlinger --display-id |"
                                                                + " grep 'Display [0-9].*pnpId=' |"
                                                                + " grep -v 'pnpId=QCM' | head -1 |"
                                                                + " cut -d' ' -f2")
                                                    .trim();
                                    if (physicalDisplayId.length() == 0) {
                                        throw new IllegalStateException(
                                                "No physical HDMI display found");
                                    }
                                    String size =
                                            rootOutput("wm size -d " + displayId)
                                                    .replaceAll("[^0-9x]", "");
                                    String[] dimensions = size.split("x");
                                    if (dimensions.length == 2) {
                                        remoteWidth = Integer.parseInt(dimensions[0]);
                                        remoteHeight = Integer.parseInt(dimensions[1]);
                                    }
                                    startDecoder(surface);
                                    startRecorder();
                                    runOnUiThread(
                                            new Runnable() {
                                                @Override
                                                public void run() {
                                                    statusView.setVisibility(View.GONE);
                                                }
                                            });
                                } catch (final Exception error) {
                                    runOnUiThread(
                                            new Runnable() {
                                                @Override
                                                public void run() {
                                                    statusView.setText(
                                                            error.getMessage() == null
                                                                    ? error.toString()
                                                                    : error.getMessage());
                                                    Toast.makeText(
                                                                    TouchControllerActivity.this,
                                                                    "TV touch control could not"
                                                                            + " start",
                                                                    Toast.LENGTH_LONG)
                                                            .show();
                                                }
                                            });
                                }
                            }
                        },
                        "tv-touch-start")
                .start();
    }

    private void startRecorder() throws Exception {
        String command =
                "echo $$ > "
                        + RECORDER_PID_FILE
                        + "; exec screenrecord --display-id "
                        + physicalDisplayId
                        + " --size "
                        + VIDEO_WIDTH
                        + "x"
                        + VIDEO_HEIGHT
                        + " --bit-rate 8M --time-limit 0 --output-format=h264 -";
        recorderProcess = new ProcessBuilder("su", "-c", command).start();
        final InputStream errors = recorderProcess.getErrorStream();
        new Thread(
                        new Runnable() {
                            @Override
                            public void run() {
                                try {
                                    while (errors.read() != -1) {}
                                } catch (Exception ignored) {
                                }
                            }
                        },
                        "tv-touch-recorder-errors")
                .start();
        final InputStream video = recorderProcess.getInputStream();
        new Thread(
                        new Runnable() {
                            @Override
                            public void run() {
                                parseAnnexB(video);
                            }
                        },
                        "tv-touch-video-reader")
                .start();
    }

    private void startDecoder(final Surface surface) throws Exception {
        decoder = MediaCodec.createDecoderByType("video/avc");
        MediaFormat format = MediaFormat.createVideoFormat("video/avc", VIDEO_WIDTH, VIDEO_HEIGHT);
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1024 * 1024);
        format.setByteBuffer(
                "csd-0",
                ByteBuffer.wrap(
                        new byte[] {
                            0,
                            0,
                            0,
                            1,
                            0x67,
                            0x64,
                            0,
                            0x1f,
                            (byte) 0xac,
                            (byte) 0xb4,
                            2,
                            (byte) 0x80,
                            0x2a,
                            (byte) 0xd0,
                            0x0d,
                            (byte) 0xa1,
                            0x42,
                            0x6a
                        }));
        format.setByteBuffer(
                "csd-1",
                ByteBuffer.wrap(
                        new byte[] {0, 0, 0, 1, 0x68, (byte) 0xee, 6, (byte) 0xf2, (byte) 0xc0}));
        decoder.configure(format, surface, null, 0);
        decoder.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT);
        decoder.start();
        new Thread(
                        new Runnable() {
                            @Override
                            public void run() {
                                decodeLoop();
                            }
                        },
                        "tv-touch-decoder")
                .start();
    }

    private void parseAnnexB(InputStream source) {
        ByteArrayOutputStream nal = new ByteArrayOutputStream(128 * 1024);
        int zeros = 0;
        byte[] chunk = new byte[64 * 1024];
        try {
            BufferedInputStream input = new BufferedInputStream(source, 128 * 1024);
            while (!stopping) {
                int count = input.read(chunk);
                if (count < 0) break;
                for (int position = 0; position < count; position++) {
                    int value = chunk[position] & 0xff;
                    if (value == 0) {
                        zeros++;
                        continue;
                    }
                    if (value == 1 && zeros >= 2) {
                        if (nal.size() > 0) {
                            nalQueue.put(nal.toByteArray());
                            nal.reset();
                        }
                        nal.write(0);
                        nal.write(0);
                        if (zeros >= 3) nal.write(0);
                        nal.write(1);
                        zeros = 0;
                    } else {
                        while (zeros-- > 0) nal.write(0);
                        zeros = 0;
                        nal.write(value);
                    }
                }
            }
            if (nal.size() > 0) nalQueue.put(nal.toByteArray());
        } catch (Exception error) {
            Log.e("TvTouch", "Video stream reader failed", error);
        } finally {
            while (!nalQueue.offer(END)) {
                nalQueue.poll();
            }
        }
    }

    private void decodeLoop() {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        long frame = 0;
        try {
            while (!stopping) {
                byte[] nal = nalQueue.poll(20, TimeUnit.MILLISECONDS);
                if (nal == END) break;
                if (nal != null) {
                    int type = nalType(nal);
                    if (frame < 10) Log.i("TvTouch", "NAL type=" + type + " bytes=" + nal.length);
                    if (type == 7 || type == 8) continue;
                    int index = -1;
                    while (!stopping && index < 0) {
                        index = decoder.dequeueInputBuffer(10000);
                        if (index < 0) drainOutput(info);
                    }
                    if (stopping || index < 0) break;
                    java.nio.ByteBuffer buffer = decoder.getInputBuffer(index);
                    if (buffer != null && nal.length <= buffer.capacity()) {
                        buffer.clear();
                        buffer.put(nal);
                        int flags = type == 5 ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0;
                        decoder.queueInputBuffer(index, 0, nal.length, frame++ * 16666L, flags);
                        if (frame == 1 || frame % 120 == 0)
                            Log.i("TvTouch", "Queued video frame " + frame);
                    } else {
                        decoder.queueInputBuffer(index, 0, 0, frame++ * 16666L, 0);
                    }
                }
                drainOutput(info);
            }
        } catch (Exception ignored) {
        }
    }

    private void drainOutput(MediaCodec.BufferInfo info) {
        if (decoder == null) return;
        int output;
        while ((output = decoder.dequeueOutputBuffer(info, 0)) >= 0) {
            decoder.releaseOutputBuffer(output, true);
        }
        if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
            Log.i("TvTouch", "Decoder output format: " + decoder.getOutputFormat());
        }
    }

    private int nalType(byte[] nal) {
        int offset = nal.length > 4 && nal[2] == 0 && nal[3] == 1 ? 4 : 3;
        return nal.length > offset ? nal[offset] & 0x1f : -1;
    }

    private boolean handleTouch(MotionEvent event) {
        if (displayId < 0) return true;
        float[] point = mapPoint(event.getX(), event.getY());
        if (point == null) return true;
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
            downX = point[0];
            downY = point[1];
            downTime = SystemClock.uptimeMillis();
            return true;
        }
        if (event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
            downTime = 0;
            return true;
        }
        if (event.getActionMasked() == MotionEvent.ACTION_UP) {
            if (downTime == 0) return true;
            long duration = Math.max(1, SystemClock.uptimeMillis() - downTime);
            float distance = Math.abs(point[0] - downX) + Math.abs(point[1] - downY);
            if (distance < Math.max(remoteWidth, remoteHeight) * 0.015f && duration < 500) {
                sendInput(
                        "input mouse -d "
                                + displayId
                                + " tap "
                                + Math.round(point[0])
                                + " "
                                + Math.round(point[1]));
            } else {
                sendInput(
                        "input mouse -d "
                                + displayId
                                + " swipe "
                                + Math.round(downX)
                                + " "
                                + Math.round(downY)
                                + " "
                                + Math.round(point[0])
                                + " "
                                + Math.round(point[1])
                                + " "
                                + duration);
            }
            downTime = 0;
            return true;
        }
        return true;
    }

    private float[] mapPoint(float x, float y) {
        float viewWidth = videoView.getWidth();
        float viewHeight = videoView.getHeight();
        float scale = Math.min(viewWidth / remoteWidth, viewHeight / remoteHeight);
        float contentWidth = remoteWidth * scale;
        float contentHeight = remoteHeight * scale;
        float left = (viewWidth - contentWidth) / 2f;
        float top = (viewHeight - contentHeight) / 2f;
        if (x < left || x > left + contentWidth || y < top || y > top + contentHeight) return null;
        return new float[] {(x - left) / scale, (y - top) / scale};
    }

    private void sendInput(final String command) {
        inputExecutor.execute(
                new Runnable() {
                    @Override
                    public void run() {
                        try {
                            Process process =
                                    new ProcessBuilder("su", "-c", command)
                                            .redirectErrorStream(true)
                                            .start();
                            if (!process.waitFor(5, TimeUnit.SECONDS)) {
                                process.destroyForcibly();
                                throw new IllegalStateException("input timed out");
                            }
                            int status = process.exitValue();
                            if (status != 0)
                                throw new IllegalStateException("input exited " + status);
                        } catch (Exception error) {
                            Log.e("TvTouch", "Touch injection failed", error);
                            runOnUiThread(
                                    new Runnable() {
                                        @Override
                                        public void run() {
                                            Toast.makeText(
                                                            TouchControllerActivity.this,
                                                            "Touch could not be sent",
                                                            Toast.LENGTH_SHORT)
                                                    .show();
                                        }
                                    });
                        }
                    }
                });
    }

    private void stopRecordedProcess() {
        try {
            rootOutput(
                    "pid=$(cat "
                            + RECORDER_PID_FILE
                            + " 2>/dev/null || true); "
                            + "case \"$pid\" in ''|*[!0-9]*) ;; *) "
                            + "if [ -r /proc/$pid/cmdline ] "
                            + "&& tr '\\0' ' ' < /proc/$pid/cmdline | grep -q screenrecord; then "
                            + "kill $pid 2>/dev/null || true; sleep 1; "
                            + "kill -9 $pid 2>/dev/null || true; fi ;; esac; "
                            + "rm -f "
                            + RECORDER_PID_FILE);
        } catch (Exception ignored) {
        }
    }

    private String rootOutput(String command) throws Exception {
        Process process = new ProcessBuilder("su", "-c", command).redirectErrorStream(true).start();
        if (!process.waitFor(12, TimeUnit.SECONDS)) {
            process.destroyForcibly();
            throw new IllegalStateException("Root command timed out");
        }
        BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()));
        StringBuilder output = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) {
            if (output.length() > 0) output.append('\n');
            output.append(line);
        }
        int status = process.exitValue();
        if (status != 0) throw new IllegalStateException(output.toString());
        return output.toString();
    }

    private synchronized void stopSession() {
        if (stopping) return;
        stopping = true;
        sessionStarted = false;
        if (recorderProcess != null) {
            recorderProcess.destroy();
            try {
                recorderProcess.destroyForcibly();
            } catch (Exception ignored) {
            }
            recorderProcess = null;
        }
        new Thread(
                        new Runnable() {
                            @Override
                            public void run() {
                                stopRecordedProcess();
                            }
                        },
                        "tv-touch-recorder-cleanup")
                .start();
        if (decoder != null) {
            try {
                decoder.stop();
            } catch (Exception ignored) {
            }
            try {
                decoder.release();
            } catch (Exception ignored) {
            }
            decoder = null;
        }
    }

    @Override
    protected void onStop() {
        super.onStop();
        if (!isChangingConfigurations()) finish();
    }

    @Override
    protected void onDestroy() {
        stopSession();
        inputExecutor.shutdownNow();
        super.onDestroy();
    }

    @Override
    public void onBackPressed() {
        finish();
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
