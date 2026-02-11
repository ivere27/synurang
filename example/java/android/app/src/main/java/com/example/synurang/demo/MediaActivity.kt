package com.example.synurang.demo

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.ImageReader
import android.media.MediaRecorder
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import android.view.Surface
import android.view.TextureView
import android.view.View
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.ImageView
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import com.example.synurang.demo.api.Media
import com.example.synurang.demo.api.MediaProcessorGrpc
import com.google.protobuf.ByteString
import io.github.ivere27.synurang.PluginHost
import io.github.ivere27.synurang.SynurangChannel
import io.grpc.stub.StreamObserver
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * Media pipeline demo using a Rust plugin for frame/audio processing.
 *
 * Camera flow (zero-copy):
 *   Camera2 -> ImageReader -> pass native Y plane pointer via FrameRef bidi stream
 *   -> Rust plugin dereferences pointer, processes Y plane in-place -> FrameResult -> display
 *   Image is kept alive until Rust signals release.
 *
 * Audio flow:
 *   AudioRecord -> PCM samples -> Rust plugin via bidi stream
 */
class MediaActivity : AppCompatActivity() {

    private lateinit var output: TextView
    private lateinit var scrollView: ScrollView
    private lateinit var spinnerResolution: Spinner
    private var availableSizes: List<Size> = emptyList()
    private var plugin: PluginHost? = null
    private var stub: MediaProcessorGrpc.MediaProcessorStub? = null
    private var audioRunning = false
    private var cameraRunning = false
    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null
    private var frameSender: StreamObserver<Media.FrameRef>? = null
    private var audioSender: StreamObserver<Media.AudioChunk>? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null

    companion object {
        private const val SAMPLE_RATE = 44100
        private const val REQUEST_PERMISSIONS = 100
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_media)

        output = findViewById(R.id.tvMediaOutput)
        scrollView = output.parent as ScrollView
        spinnerResolution = findViewById(R.id.spinnerResolution)

        // Populate resolution dropdown from camera characteristics
        try {
            val manager = getSystemService(CAMERA_SERVICE) as CameraManager
            val cameraId = manager.cameraIdList.firstOrNull()
            if (cameraId != null) {
                val chars = manager.getCameraCharacteristics(cameraId)
                val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                val sizes = map?.getOutputSizes(android.graphics.ImageFormat.YUV_420_888) ?: emptyArray()
                availableSizes = sizes.sortedByDescending { it.width * it.height }
                val labels = availableSizes.map { "${it.width}x${it.height}" }
                spinnerResolution.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, labels)
                // Default to 640x480 if available
                val defaultIdx = availableSizes.indexOfFirst { it.width == 640 && it.height == 480 }
                if (defaultIdx >= 0) spinnerResolution.setSelection(defaultIdx)
            }
        } catch (e: Exception) {
            log("Failed to query resolutions: ${e.message}")
        }

        // Load Rust media plugin
        thread {
            try {
                val libDir = applicationInfo.nativeLibraryDir
                val pluginPath = "$libDir/libplugin_media.so"
                if (File(pluginPath).exists()) {
                    val p = PluginHost.load(pluginPath)
                    plugin = p
                    val channel = SynurangChannel.create(p, "MediaProcessor")
                    stub = MediaProcessorGrpc.newStub(channel)
                    log("Rust media plugin loaded")
                } else {
                    log("Plugin not found: $pluginPath")
                    log("Build: make build_plugin_media_android")
                }
            } catch (e: Throwable) {
                log("Failed to load plugin: ${e.javaClass.simpleName}: ${e.message}")
            }
        }

        findViewById<Button>(R.id.btnStartCamera).setOnClickListener { startCameraProcessing() }
        findViewById<Button>(R.id.btnStopCamera).setOnClickListener { stopCameraProcessing() }
        findViewById<Button>(R.id.btnStartAudio).setOnClickListener { startAudioProcessing() }
        findViewById<Button>(R.id.btnStopAudio).setOnClickListener { stopAudioProcessing() }

        // Request permissions
        val perms = arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
        val needed = perms.filter {
            ActivityCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (needed.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, needed.toTypedArray(), REQUEST_PERMISSIONS)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (audioRunning) stopAudioProcessing()
        if (cameraRunning) stopCameraProcessing()
        // Don't close plugin here — Rust handler threads may still be draining.
        // Cleanup happens when the process exits.
    }

    // =========================================================================
    // Camera Processing — zero-copy: native pointer passed to Rust via FFI
    // =========================================================================

    private fun startCameraProcessing() {
        val s = stub ?: return log("Plugin not loaded")

        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) {
            log("Camera permission not granted")
            return
        }

        cameraRunning = true
        spinnerResolution.isEnabled = false
        findViewById<Button>(R.id.btnStartCamera).isEnabled = false
        findViewById<Button>(R.id.btnStopCamera).isEnabled = true
        cameraThread = HandlerThread("CameraThread").also { it.start() }
        cameraHandler = Handler(cameraThread!!.looper)

        val manager = getSystemService(CAMERA_SERVICE) as CameraManager
        val cameraId = manager.cameraIdList.firstOrNull() ?: return log("No camera found")

        // Get selected resolution from spinner
        val selectedSize = if (availableSizes.isNotEmpty() && spinnerResolution.selectedItemPosition >= 0) {
            availableSizes[spinnerResolution.selectedItemPosition]
        } else {
            Size(640, 480)
        }

        log("Opening camera: $cameraId at ${selectedSize.width}x${selectedSize.height}")

        val chars = manager.getCameraCharacteristics(cameraId)
        val sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val processedView = findViewById<ImageView>(R.id.processedView)
        processedView.visibility = View.VISIBLE

        // Only 1 frame in-flight to Rust at a time (pointer must stay valid until processed)
        val processingFrame = AtomicBoolean(false)
        val pendingImage = AtomicReference<android.media.Image?>(null)
        val cameraFrameCount = java.util.concurrent.atomic.AtomicInteger(0)

        // Pre-allocate Bitmap + buffers
        val frameW = selectedSize.width
        val frameH = selectedSize.height
        val pixels = IntArray(frameW * frameH)
        val rowBuf = ByteArray(frameW)
        val bitmap = Bitmap.createBitmap(frameW, frameH, Bitmap.Config.ARGB_8888)
        // Y→ARGB lookup table: eliminates bit ops per pixel
        val lut = IntArray(256) { y -> (0xFF shl 24) or (y shl 16) or (y shl 8) or y }
        // Rotate the View instead of per-pixel rotation (GPU-accelerated)
        processedView.rotation = sensorOrientation.toFloat()
        log("frame: ${frameW}x${frameH}  sensor: ${sensorOrientation}deg (view rotation)")

        // Open bidi stream via gRPC stub
        var frameCount = 0
        var lastLogTime = System.currentTimeMillis()

        val responseObserver = object : StreamObserver<Media.FrameResult> {
            override fun onNext(stats: Media.FrameResult) {
                // Draining after stop — just release image safely
                if (!cameraRunning) {
                    pendingImage.getAndSet(null)?.close()
                    processingFrame.set(false)
                    return
                }
                frameCount++

                // Read modified Y plane back (same pointer Rust wrote to)
                val img = pendingImage.get()
                if (img != null) {
                    val yPlane = img.planes[0]
                    val yBuf = yPlane.buffer
                    val stride = yPlane.rowStride
                    yBuf.rewind()
                    for (row in 0 until frameH) {
                        yBuf.position(row * stride)
                        yBuf.get(rowBuf, 0, frameW)
                        val off = row * frameW
                        for (col in 0 until frameW) {
                            pixels[off + col] = lut[rowBuf[col].toInt() and 0xFF]
                        }
                    }
                    bitmap.setPixels(pixels, 0, frameW, 0, 0, frameW, frameH)
                    runOnUiThread { processedView.setImageBitmap(bitmap) }
                }

                // Release the image — done reading
                pendingImage.getAndSet(null)?.close()
                processingFrame.set(false)

                // Log status once per second
                val now = System.currentTimeMillis()
                if (now - lastLogTime >= 1000) {
                    val camFps = cameraFrameCount.getAndSet(0) * 1000.0 / (now - lastLogTime)
                    log("${frameW}x${frameH} cam:${String.format("%.0f", camFps)} rust:${String.format("%.0f", stats.rustFps)} fps | RSS ${stats.rssMb}MB CPU ${String.format("%.0f", stats.cpuPercent)}%")
                    frameCount = 0
                    lastLogTime = now
                }
            }

            override fun onError(t: Throwable) {
                pendingImage.getAndSet(null)?.close()
                if (cameraRunning) log("Frame stream error: ${t.message}")
            }

            override fun onCompleted() {
                pendingImage.getAndSet(null)?.close()
            }
        }

        val sender = s.processFrames(responseObserver)
        frameSender = sender

        val imageReader = ImageReader.newInstance(frameW, frameH, android.graphics.ImageFormat.YUV_420_888, 8)

        imageReader.setOnImageAvailableListener({ reader ->
            if (!cameraRunning) return@setOnImageAvailableListener
            cameraFrameCount.incrementAndGet()
            // Skip if Rust is still processing previous frame (keep preview flowing)
            if (processingFrame.get()) {
                reader.acquireLatestImage()?.close()
                return@setOnImageAvailableListener
            }
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val yPlane = image.planes[0]
                val yBuffer = yPlane.buffer

                // Zero-copy: get native address of DirectByteBuffer via JNI
                val nativeAddr = PluginHost.getDirectBufferAddress(yBuffer)
                val dataSize = yBuffer.remaining()
                val rowStride = yPlane.rowStride

                // Build FrameRef with native pointer (no byte copy!)
                val frameRef = Media.FrameRef.newBuilder()
                    .setHandle(nativeAddr)
                    .setWidth(image.width)
                    .setHeight(image.height)
                    .setFormat(image.format)
                    .setTimestampNs(image.timestamp)
                    .setDataSize(dataSize)
                    .setRowStride(rowStride)
                    .build()
                pendingImage.set(image)
                processingFrame.set(true)
                sender.onNext(frameRef)
            } catch (e: Exception) {
                image.close()
            }
        }, cameraHandler)

        val textureView = findViewById<TextureView>(R.id.textureView)
        if (textureView.isAvailable) {
            openCamera(manager, cameraId, textureView, imageReader, frameW, frameH)
        } else {
            textureView.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(st: SurfaceTexture, w: Int, h: Int) {
                    openCamera(manager, cameraId, textureView, imageReader, frameW, frameH)
                }
                override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w: Int, h: Int) {}
                override fun onSurfaceTextureDestroyed(st: SurfaceTexture) = true
                override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
            }
        }
    }

    private fun stopCameraProcessing() {
        cameraRunning = false
        captureSession?.close()
        captureSession = null
        cameraDevice?.close()
        cameraDevice = null
        // onCompleted triggers Rust to finish current frame and exit gracefully.
        // The response observer's onCompleted drains the final response and releases the Image.
        frameSender?.onCompleted()
        frameSender = null
        cameraThread?.quitSafely()
        cameraThread = null
        cameraHandler = null
        findViewById<ImageView>(R.id.processedView).visibility = View.GONE
        findViewById<Button>(R.id.btnStartCamera).isEnabled = true
        findViewById<Button>(R.id.btnStopCamera).isEnabled = false
        spinnerResolution.isEnabled = true
        log("Camera stopped")
    }

    private fun openCamera(
        manager: CameraManager,
        cameraId: String,
        textureView: TextureView,
        imageReader: ImageReader,
        width: Int,
        height: Int
    ) {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED) return

        // Query max FPS range
        val chars = manager.getCameraCharacteristics(cameraId)
        val fpsRanges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
        val maxRange = fpsRanges?.maxByOrNull { it.upper }

        manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                cameraDevice = camera
                val texture = textureView.surfaceTexture ?: return
                texture.setDefaultBufferSize(width, height)
                val previewSurface = Surface(texture)
                val imageSurface = imageReader.surface

                val builder = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                builder.addTarget(imageSurface)

                // Set max FPS
                if (maxRange != null) {
                    builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, maxRange)
                    log("FPS range: ${maxRange.lower}-${maxRange.upper}")
                }

                camera.createCaptureSession(
                    listOf(imageSurface),
                    object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(session: CameraCaptureSession) {
                            captureSession = session
                            session.setRepeatingRequest(builder.build(), null, cameraHandler)
                            log("Camera started")
                        }
                        override fun onConfigureFailed(session: CameraCaptureSession) {
                            log("Camera configuration failed")
                        }
                    },
                    cameraHandler
                )
            }

            override fun onDisconnected(camera: CameraDevice) { camera.close() }
            override fun onError(camera: CameraDevice, error: Int) {
                log("Camera error: $error")
                camera.close()
            }
        }, cameraHandler)
    }

    // =========================================================================
    // Audio Processing
    // =========================================================================

    private fun startAudioProcessing() {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED) {
            log("Audio permission not granted")
            return
        }
        val s = stub ?: return log("Plugin not loaded")

        audioRunning = true
        findViewById<Button>(R.id.btnStartAudio).isEnabled = false
        findViewById<Button>(R.id.btnStopAudio).isEnabled = true

        // Open audio bidi stream via gRPC stub — drain responses to prevent backpressure
        val responseObserver = object : StreamObserver<Media.AudioChunk> {
            override fun onNext(value: Media.AudioChunk) {}
            override fun onError(t: Throwable) {
                if (audioRunning) log("Audio stream error: ${t.message}")
            }
            override fun onCompleted() {}
        }

        val sender = s.processAudio(responseObserver)
        audioSender = sender

        thread {
            try {
                val bufferSize = AudioRecord.getMinBufferSize(
                    SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                )

                val recorder = AudioRecord(
                    MediaRecorder.AudioSource.MIC,
                    SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    bufferSize
                )

                recorder.startRecording()
                log("Audio recording started")

                val buffer = ByteArray(bufferSize)

                while (audioRunning) {
                    val read = recorder.read(buffer, 0, buffer.size)
                    if (read > 0) {
                        val chunk = Media.AudioChunk.newBuilder()
                            .setData(ByteString.copyFrom(buffer, 0, read))
                            .setSampleRate(SAMPLE_RATE)
                            .build()
                        sender.onNext(chunk)
                    }
                }

                recorder.stop()
                recorder.release()
                log("Audio stopped")
            } catch (e: Exception) {
                log("Audio error: ${e.message}")
            }

            sender.onCompleted()
            runOnUiThread {
                findViewById<Button>(R.id.btnStartAudio).isEnabled = true
                findViewById<Button>(R.id.btnStopAudio).isEnabled = false
            }
        }
    }

    private fun stopAudioProcessing() {
        audioRunning = false
        // Let the send thread exit its loop and call onCompleted() naturally.
        // Rust finishes and the response observer gets onCompleted.
        // Don't force-close — it would kill Rust mid-processing.
    }

    private fun log(msg: String) {
        runOnUiThread {
            output.append(msg + "\n")
            scrollView.post { scrollView.fullScroll(ScrollView.FOCUS_DOWN) }
        }
    }
}
