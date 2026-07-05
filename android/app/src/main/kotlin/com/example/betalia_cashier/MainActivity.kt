package com.example.betalia_cashier

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import kotlinx.coroutines.*
import java.util.concurrent.atomic.AtomicBoolean

// Verifone PSDK Imports
import com.verifone.payment_sdk.*

@Suppress("DEPRECATION")
class MainActivity : FlutterActivity() {
    private val channelName = "com.betalia.payments/p630"
    private var paymentSdk: PaymentSdk? = null
    private var transactionManager: TransactionManager? = null

    private var isInitialized = false
    private var isLoggedIn = false
    private var isSessionOpen = false
    private var terminalIpAddress: String = ""
    private var pendingTransactionLock = AtomicBoolean(false)

    // Coroutine exception handler — prevents crashes
    private val exceptionHandler = CoroutineExceptionHandler { _, throwable ->
        Log.e("Verifone", "Unhandled coroutine exception", throwable)
        showToast("Internal Error: ${throwable.localizedMessage}")
        try {
            showNativeErrorDialog("App Error", throwable.localizedMessage ?: "Unknown error")
        } catch (_: Exception) {}
        pendingTransactionLock.set(false)
        isSessionOpen = false
    }

    private val psdkScope = CoroutineScope(Dispatchers.IO + SupervisorJob() + exceptionHandler)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "configureTerminal" -> {
                            val ip = call.argument<String>("ipAddress") ?: ""
                            val port = call.argument<String>("port") ?: ""
                            configureAndInitializeTerminal(ip, port, result)
                        }
                        "startTransaction" -> {
                            val amount = call.argument<Double>("amount") ?: 0.0
                            val currency = call.argument<String>("currency") ?: "NOK"
                            runVerifoneTransaction(amount, currency, result)
                        }
                        "checkTerminalStatus" -> {
                            checkStatus(result)
                        }
                        "endSession" -> {
                            endVerifoneSession(result)
                        }
                        "disconnect" -> {
                            disconnectTerminal(result)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Throwable) {
                    Log.e("Verifone", "Unexpected error in MethodChannel handler", e)
                    showToast("System Error: ${e.localizedMessage}")
                    try { result.error("UNEXPECTED_ERROR", e.localizedMessage, null) } catch (_: Exception) {}
                }
            }
    }

    // ================================================================
    // INITIALIZATION
    // ================================================================

    private fun configureAndInitializeTerminal(
        ip: String,
        port: String,
        flutterResult: MethodChannel.Result
    ) {
        if (ip.isBlank()) {
            flutterResult.error("INVALID_IP", "Terminal IP address is required", null)
            return
        }
        terminalIpAddress = ip.trim()
        Log.i("Verifone", "Configuring terminal at $terminalIpAddress")

        psdkScope.launch {
            try {
                // Tear down previous instance if exists
                if (paymentSdk != null) {
                    Log.d("Verifone", "Tearing down previous SDK instance...")
                    try { paymentSdk?.tearDown() } catch (_: Exception) {}
                    delay(500)
                }

                // Step 1: Create PaymentSdk
                paymentSdk = PaymentSdk.create(this@MainActivity)
                Log.d("Verifone", "PaymentSdk created")

                // Step 2: Build TCP/IP connection params
                val paramMap: HashMap<String, String> = hashMapOf(
                    PsdkDeviceInformation.DEVICE_CONNECTION_TYPE_KEY to "tcpip",
                    PsdkDeviceInformation.DEVICE_ADDRESS_KEY to terminalIpAddress
                )

                // Step 3: Create commerce listener
                val initListener = object : CommerceListenerAdapter() {
                    override fun handleStatus(status: Status) {
                        try {
                            Log.d("Verifone", "Init status: code=${status.status}")
                            if (status.status == StatusCode.SUCCESS) {
                                isInitialized = true
                                Log.i("Verifone", "PSDK Initialized successfully!")

                                transactionManager = paymentSdk?.transactionManager
                                Log.d("Verifone", "TransactionManager: ${transactionManager != null}")

                                loginToTerminal()

                                runOnUiThread {
                                    showToast("Verifone Terminal Connected")
                                    flutterResult.success("CONNECTED")
                                }
                            } else {
                                isInitialized = false
                                val errMsg = status.message ?: "Init failed"
                                Log.e("Verifone", "$errMsg (${status.status})")
                                runOnUiThread {
                                    showToast(errMsg)
                                    flutterResult.error("INIT_FAILED", errMsg, status.status.toString())
                                }
                            }
                        } catch (e: Exception) {
                            Log.e("Verifone", "Error in init listener", e)
                            runOnUiThread {
                                flutterResult.error("INIT_ERROR", e.localizedMessage, null)
                            }
                        }
                    }
                }

                paymentSdk?.addListener(initListener)
                paymentSdk?.initializeFromValues(initListener, paramMap)
                Log.d("Verifone", "initializeFromValues called with IP: $terminalIpAddress")

            } catch (e: Exception) {
                Log.e("Verifone", "Failed to initialize PSDK", e)
                runOnUiThread {
                    showToast("Init Error: ${e.localizedMessage}")
                    flutterResult.error("INIT_ERROR", e.localizedMessage, null)
                }
            }
        }
    }

    // ================================================================
    // LOGIN / LOGOUT
    // ================================================================

    private fun loginToTerminal() {
        psdkScope.launch {
            try {
                val tm = transactionManager ?: run {
                    Log.e("Verifone", "Cannot login — TransactionManager is null")
                    return@launch
                }
                val credentials = LoginCredentials.createWith2(null, null, null, null)
                val status = tm.loginWithCredentials(credentials)
                if (status.status == StatusCode.SUCCESS) {
                    Log.i("Verifone", "Login request sent successfully")
                } else {
                    Log.e("Verifone", "Login request failed: ${status.message}")
                }
            } catch (e: Exception) {
                Log.e("Verifone", "Login exception", e)
            }
        }
    }

    private fun logoutFromTerminal() {
        psdkScope.launch {
            try {
                transactionManager?.logout()
                isLoggedIn = false
                Log.d("Verifone", "Logout called")
            } catch (e: Exception) {
                Log.e("Verifone", "Logout exception", e)
            }
        }
    }

    // ================================================================
    // SESSION MANAGEMENT
    // ================================================================

    private fun endVerifoneSession(flutterResult: MethodChannel.Result) {
        psdkScope.launch {
            try {
                val tm = transactionManager ?: run {
                    runOnUiThread { flutterResult.error("NO_MANAGER", "Not connected", null) }
                    return@launch
                }
                tm.endSession()
                isSessionOpen = false
                Log.i("Verifone", "EndSession called")
                runOnUiThread { flutterResult.success("SESSION_ENDED") }
            } catch (e: Exception) {
                Log.e("Verifone", "End session exception", e)
                runOnUiThread { flutterResult.error("END_SESSION_ERROR", e.localizedMessage, null) }
            }
        }
    }

    // ================================================================
    // DISCONNECT / TEARDOWN
    // ================================================================

    private fun disconnectTerminal(flutterResult: MethodChannel.Result) {
        psdkScope.launch {
            try {
                logoutFromTerminal()
                delay(300)
                paymentSdk?.tearDown()
                paymentSdk = null
                transactionManager = null
                isInitialized = false
                isLoggedIn = false
                isSessionOpen = false
                Log.i("Verifone", "Terminal disconnected")
                runOnUiThread { flutterResult.success("DISCONNECTED") }
            } catch (e: Exception) {
                Log.e("Verifone", "Disconnect exception", e)
                runOnUiThread { flutterResult.error("DISCONNECT_ERROR", e.localizedMessage, null) }
            }
        }
    }

    // ================================================================
    // PAYMENT TRANSACTION
    // ================================================================

    private fun runVerifoneTransaction(
        amount: Double,
        currency: String,
        flutterResult: MethodChannel.Result
    ) {
        if (!pendingTransactionLock.compareAndSet(false, true)) {
            flutterResult.error("BUSY", "A transaction is already in progress", null)
            return
        }

        psdkScope.launch {
            try {
                val tm = transactionManager
                if (tm == null) {
                    Log.e("Verifone", "No TransactionManager — need to initialize first")
                    runOnUiThread {
                        flutterResult.error("NOT_CONNECTED",
                            "Terminal not connected. Call configureTerminal first.", null)
                    }
                    pendingTransactionLock.set(false)
                    return@launch
                }

                val paymentListener = createPaymentListener(flutterResult)
                paymentSdk?.addListener(paymentListener)

                // Open session if needed
                if (!isSessionOpen) {
                    Log.d("Verifone", "Opening session...")
                    val txn = Transaction.create()
                    txn.currency = currency
                    try {
                        tm.startSession2(txn)
                        delay(1000)
                        isSessionOpen = true
                    } catch (e: Exception) {
                        Log.e("Verifone", "Session start failed", e)
                        runOnUiThread {
                            flutterResult.error("SESSION_FAILED", e.localizedMessage, null)
                        }
                        paymentSdk?.removeListener(paymentListener)
                        pendingTransactionLock.set(false)
                        return@launch
                    }
                }

                // Build payment
                val payment = Payment.create()
                payment.transactionType = TransactionType.PAYMENT
                payment.currency = currency

                val amounts = AmountTotals.create(true)
                val cents = Math.round(amount * 100.0)
                amounts.total = Decimal(cents.toDouble() / 100.0)
                payment.requestedAmounts = amounts

                Log.i("Verifone", "Starting payment: $amount $currency")
                showToast("Processing: $amount $currency...")

                val startStatus = tm.startPayment(payment)
                if (startStatus.status != StatusCode.SUCCESS) {
                    val failMsg = startStatus.message ?: "Could not start payment"
                    Log.e("Verifone", "startPayment failed: $failMsg")
                    runOnUiThread {
                        showToast("Payment Failed: $failMsg")
                        flutterResult.error("START_FAILED", failMsg, startStatus.status.toString())
                    }
                    paymentSdk?.removeListener(paymentListener)
                    endSessionQuietly()
                    pendingTransactionLock.set(false)
                    return@launch
                }

                Log.d("Verifone", "startPayment sent, awaiting result...")

            } catch (e: Exception) {
                Log.e("Verifone", "Transaction exception", e)
                runOnUiThread {
                    flutterResult.error("TX_ERROR", e.localizedMessage, null)
                }
                pendingTransactionLock.set(false)
            }
        }
    }

    private fun createPaymentListener(flutterResult: MethodChannel.Result): CommerceListenerAdapter {
        return object : CommerceListenerAdapter() {

            override fun handleTransactionEvent(event: TransactionEvent) {
                try {
                    Log.d("Verifone", "Transaction event: ${event.type}, status=${event.status}")
                    // Track login/session state based on events
                } catch (e: Exception) {
                    Log.e("Verifone", "Error in transaction event handler", e)
                }
            }

            override fun handlePaymentCompletedEvent(event: PaymentCompletedEvent) {
                try {
                    Log.d("Verifone", "PaymentCompleted: status=${event.status}")

                    paymentSdk?.removeListener(this)
                    pendingTransactionLock.set(false)

                    if (event.status == StatusCode.SUCCESS) {
                        val payment = event.payment
                        val authResult = payment?.authResult

                        Log.i("Verifone", "Payment done. AuthResult: $authResult")

                        if (authResult == AuthorizationResult.AUTHORIZED) {
                            runOnUiThread {
                                showToast("PAYMENT APPROVED ✓")
                                flutterResult.success(
                                    buildJsonResponse("APPROVED", authResult.toString(),
                                        payment?.transactionId,
                                        payment?.retrievalReferenceNumber)
                                )
                            }
                        } else {
                            val resultStr = authResult?.toString() ?: "UNKNOWN"
                            runOnUiThread {
                                showToast("Payment: $resultStr")
                                flutterResult.success(
                                    buildJsonResponse("COMPLETED", resultStr, null, null)
                                )
                            }
                        }
                    } else {
                        val errorMsg = event.message ?: "Payment failed"
                        Log.e("Verifone", "Payment failed: $errorMsg (${event.status})")
                        runOnUiThread {
                            showToast("Payment Error: $errorMsg")
                            flutterResult.error("PAYMENT_FAILED", errorMsg, event.status.toString())
                        }
                    }

                    endSessionQuietly()

                } catch (e: Exception) {
                    Log.e("Verifone", "Error handling payment completion", e)
                    try {
                        pendingTransactionLock.set(false)
                        runOnUiThread {
                            flutterResult.error("HANDLER_ERROR", e.localizedMessage, null)
                        }
                    } catch (_: Exception) {}
                }
            }

            override fun handleStatus(status: Status) {
                try {
                    Log.d("Verifone", "SDK Status: code=${status.status}, msg=${status.message}")
                } catch (_: Exception) {}
            }
        }
    }

    private fun endSessionQuietly() {
        psdkScope.launch {
            try {
                delay(500)
                if (isSessionOpen) {
                    transactionManager?.endSession()
                    isSessionOpen = false
                    Log.d("Verifone", "Session ended (quiet)")
                }
            } catch (e: Exception) {
                Log.e("Verifone", "End session error (quiet)", e)
            }
        }
    }

    // ================================================================
    // STATUS CHECK
    // ================================================================

    private fun checkStatus(result: MethodChannel.Result) {
        try {
            val connected = isInitialized && paymentSdk != null && transactionManager != null
            val statusStr = if (connected) "CONNECTED" else "NOT_CONNECTED"

            result.success(
                buildJsonResponse(statusStr, null, null, null) {
                    put("ipAddress", terminalIpAddress)
                    put("isLoggedIn", isLoggedIn)
                    put("isSessionOpen", isSessionOpen)
                }
            )
        } catch (e: Exception) {
            Log.e("Verifone", "Status check failed", e)
            result.error("STATUS_ERROR", e.localizedMessage, null)
        }
    }

    // ================================================================
    // UTILITY
    // ================================================================

    private fun buildJsonResponse(
        status: String,
        authResult: String?,
        transactionId: String?,
        rrn: String?,
        extra: (org.json.JSONObject.() -> Unit)? = null
    ): String {
        return org.json.JSONObject().apply {
            put("status", status)
            if (authResult != null) put("authResult", authResult)
            if (transactionId != null) put("transactionId", transactionId)
            if (rrn != null) put("rrn", rrn)
            extra?.invoke(this)
        }.toString()
    }

    private fun showToast(message: String) {
        runOnUiThread {
            Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        }
    }

    private fun showNativeErrorDialog(title: String, message: String) {
        runOnUiThread {
            try {
                AlertDialog.Builder(this)
                    .setTitle(title)
                    .setMessage(message)
                    .setPositiveButton("OK") { dialog, _ -> dialog.dismiss() }
                    .setCancelable(false)
                    .show()
            } catch (e: Exception) {
                Log.e("Verifone", "Failed to show native dialog", e)
            }
        }
    }

    override fun onDestroy() {
        psdkScope.cancel()
        try { paymentSdk?.tearDown() } catch (_: Exception) {}
        super.onDestroy()
    }
}