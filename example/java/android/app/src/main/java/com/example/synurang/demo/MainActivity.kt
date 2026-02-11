package com.example.synurang.demo

import android.content.Intent
import android.os.Bundle
import android.widget.Button
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import example.v1.Example.HelloRequest
import example.v1.Example.HelloResponse
import example.v1.GoGreeterServiceGrpc
import io.github.ivere27.synurang.PluginHost
import io.github.ivere27.synurang.ProcessHost
import io.github.ivere27.synurang.SynurangChannel
import io.grpc.ManagedChannel
import io.grpc.stub.StreamObserver
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Synurang demo: loads a Go plugin .so and tests all 4 RPC types
 * using standard protoc-gen-grpc-java stubs via [SynurangChannel].
 *
 * The Go plugin must be compiled for Android ABIs and placed in the app's
 * native library directory (e.g., jniLibs/arm64-v8a/libplugin_go.so).
 */
class MainActivity : AppCompatActivity() {

    private lateinit var scrollView: ScrollView
    private lateinit var output: TextView
    private var plugin: PluginHost? = null
    private var channel: SynurangChannel? = null
    private var processHost: ProcessHost? = null
    private var processChannel: ManagedChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        scrollView = findViewById(R.id.scrollOutput)
        output = findViewById(R.id.tvOutput)

        val libDir = applicationInfo.nativeLibraryDir

        // Load plugin on startup
        thread {
            try {
                val pluginPath = "$libDir/libplugin_go.so"
                if (File(pluginPath).exists()) {
                    val p = PluginHost.load(pluginPath)
                    plugin = p
                    channel = SynurangChannel.create(p, "GoGreeterService")
                    log("Plugin loaded (drop-in gRPC channel ready)")
                } else {
                    log("Plugin not found: $pluginPath")
                    log("Build the Go plugin for Android first.")
                }
            } catch (e: Throwable) {
                log("Failed to load plugin: ${e.javaClass.simpleName}: ${e.message}")
                e.cause?.let { log("  Caused by: ${it.javaClass.simpleName}: ${it.message}") }
            }
        }

        // Start Go process child on startup (socketpair IPC)
        thread {
            try {
                val processPath = "$libDir/libprocess_go.so"
                if (File(processPath).exists()) {
                    val proc = ProcessHost.start(processPath)
                    processHost = proc
                    processChannel = proc.channel() as ManagedChannel
                    log("Go process started (pid=${proc.pid}, socketpair IPC ready)")
                } else {
                    log("Process binary not found: $processPath")
                    log("Build with: make build_process_go_android")
                }
            } catch (e: Throwable) {
                log("Failed to start process: ${e.javaClass.simpleName}: ${e.message}")
            }
        }

        findViewById<Button>(R.id.btnUnary).setOnClickListener { testUnary() }
        findViewById<Button>(R.id.btnServerStream).setOnClickListener { testServerStream() }
        findViewById<Button>(R.id.btnClientStream).setOnClickListener { testClientStream() }
        findViewById<Button>(R.id.btnBidiStream).setOnClickListener { testBidiStream() }
        findViewById<Button>(R.id.btnProcessUnary).setOnClickListener { testProcessUnary() }
        findViewById<Button>(R.id.btnProcessBidi).setOnClickListener { testProcessBidi() }
        findViewById<Button>(R.id.btnMedia).setOnClickListener {
            startActivity(Intent(this, MediaActivity::class.java))
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        processHost?.close()
        plugin?.close()
    }

    // =========================================================================
    // RPC Tests — standard grpc-java stubs, zero custom codegen
    // =========================================================================

    private fun testUnary() {
        val ch = channel ?: return log("Plugin not loaded")
        thread {
            try {
                log("\n[Unary RPC]")
                val stub = GoGreeterServiceGrpc.newBlockingStub(ch)
                val resp = stub.bar(HelloRequest.newBuilder().setName("AndroidUser").build())
                log("Response: ${resp.message}")
            } catch (e: Exception) {
                log("Error: ${e.message}")
            }
        }
    }

    private fun testServerStream() {
        val ch = channel ?: return log("Plugin not loaded")
        thread {
            try {
                log("\n[Server Streaming]")
                val stub = GoGreeterServiceGrpc.newBlockingStub(ch)
                val iter = stub.barServerStream(
                    HelloRequest.newBuilder().setName("StreamTest").build()
                )
                var count = 0
                while (iter.hasNext()) {
                    val resp = iter.next()
                    count++
                    log("  [$count] ${resp.message}")
                }
                log("Server stream complete: $count messages")
            } catch (e: Exception) {
                log("Error: ${e.message}")
            }
        }
    }

    private fun testClientStream() {
        val ch = channel ?: return log("Plugin not loaded")
        thread {
            try {
                log("\n[Client Streaming]")
                val asyncStub = GoGreeterServiceGrpc.newStub(ch)
                val latch = CountDownLatch(1)
                var response: HelloResponse? = null
                var error: Throwable? = null

                val sender = asyncStub.barClientStream(object : StreamObserver<HelloResponse> {
                    override fun onNext(value: HelloResponse) { response = value }
                    override fun onError(t: Throwable) { error = t; latch.countDown() }
                    override fun onCompleted() { latch.countDown() }
                })

                for (i in 0..2) {
                    sender.onNext(HelloRequest.newBuilder().setName("Msg$i").build())
                    log("  Sent: Msg$i")
                }
                sender.onCompleted()

                latch.await(10, TimeUnit.SECONDS)
                if (error != null) throw error!!
                log("Response: ${response?.message}")
            } catch (e: Exception) {
                log("Error: ${e.message}")
            }
        }
    }

    private fun testBidiStream() {
        val ch = channel ?: return log("Plugin not loaded")
        thread {
            try {
                log("\n[Bidi Streaming]")
                val asyncStub = GoGreeterServiceGrpc.newStub(ch)
                val latch = CountDownLatch(1)
                val responses = mutableListOf<String>()
                var error: Throwable? = null

                val sender = asyncStub.barBidiStream(object : StreamObserver<HelloResponse> {
                    override fun onNext(value: HelloResponse) { responses.add(value.message) }
                    override fun onError(t: Throwable) { error = t; latch.countDown() }
                    override fun onCompleted() { latch.countDown() }
                })

                for (i in 0..2) {
                    sender.onNext(HelloRequest.newBuilder().setName("Ping$i").build())
                }
                sender.onCompleted()

                latch.await(10, TimeUnit.SECONDS)
                if (error != null) throw error!!
                responses.forEachIndexed { idx, msg ->
                    log("  Echo [${idx + 1}]: $msg")
                }
                log("Bidi stream complete: ${responses.size} echoes")
            } catch (e: Exception) {
                log("Error: ${e.message}")
            }
        }
    }

    // =========================================================================
    // Process Mode — Go child via socketpair IPC, standard gRPC channel
    // =========================================================================

    private fun testProcessUnary() {
        val ch = processChannel ?: return log("Process not started")
        thread {
            try {
                log("\n[Process: Unary RPC]")
                val stub = GoGreeterServiceGrpc.newBlockingStub(ch)
                val resp = stub.bar(HelloRequest.newBuilder().setName("ProcessUser").build())
                log("Response: ${resp.message}")
            } catch (e: Exception) {
                log("Error: ${e.message}")
            }
        }
    }

    private fun testProcessBidi() {
        val ch = processChannel ?: return log("Process not started")
        thread {
            try {
                log("\n[Process: Bidi Streaming]")
                val asyncStub = GoGreeterServiceGrpc.newStub(ch)
                val latch = CountDownLatch(1)
                val responses = mutableListOf<String>()
                var error: Throwable? = null

                val sender = asyncStub.barBidiStream(object : StreamObserver<HelloResponse> {
                    override fun onNext(value: HelloResponse) { responses.add(value.message) }
                    override fun onError(t: Throwable) { error = t; latch.countDown() }
                    override fun onCompleted() { latch.countDown() }
                })

                for (i in 0..2) {
                    sender.onNext(HelloRequest.newBuilder().setName("Ping$i").build())
                }
                sender.onCompleted()

                latch.await(10, TimeUnit.SECONDS)
                if (error != null) throw error!!
                responses.forEachIndexed { idx, msg ->
                    log("  Echo [${idx + 1}]: $msg")
                }
                log("Bidi stream complete: ${responses.size} echoes")
            } catch (e: Exception) {
                log("Error: ${e.message}")
            }
        }
    }

    private fun log(msg: String) {
        runOnUiThread {
            output.append(msg + "\n")
            scrollView.post { scrollView.fullScroll(ScrollView.FOCUS_DOWN) }
        }
    }
}
