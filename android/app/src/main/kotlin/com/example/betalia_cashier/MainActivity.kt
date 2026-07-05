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

    // Pending flutter result while we wait for init/login
    private var pendingFlutterResult: MethodChannel.Result? = null

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

    // ── COMMERCE LISTENER (matching reference app: transactionManager at top, STATUS_INITIALIZED check) ──
    private lateinit var commerceListener: CommerceListenerAdapter

    private fun createCommerceListener() {
        commerceListener = object : CommerceListenerAdapter() {
            override fun handleStatus(status: Status) {
                try {
                    // TOP of handleStatus: ALWAYS get transactionManager (matches reference app line 299)
                    transactionManager = paymentSdk?.transactionManager
                    Log.d("Verifone", "Status: type=${status.type}, code=${status.status}, msg=${status.message}")

                    // Match reference app: check STATUS_INITIALIZED type
                    if (status.type == Status.STATUS_INITIALIZED) {
                        if (status.status == StatusCode.SUCCESS) {
                            isInitialized = true
                            Log.i("Verifone", "PSDK Initialized!")
                            loginToTerminal()
                            runOnUiThread {
                                showToast("Verifone Connected")
                                pendingFlutterResult?.success("CONNECTED")
                                pendingFlutterResult = null
                            }
                        } else if (status.status == StatusCode.CONFIGURATION_REQUIRED) {
                            // Terminal needs first-time pairing — launch Verifone config UI
                            Log.w("Verifone", "Configuration required — launching pairing UI")
                            runOnUiThread {
                                try {
                                    val activity = this@MainActivity
                                    paymentSdk?.displayConfiguration(commerceListener, activity)
                                    showToast("Select P630 terminal from the list")
                                } catch (e: Exception) {
                                    Log.e("Verifone", "displayConfiguration failed", e)
                                    showToast("Pairing error: ${e.localizedMessage}")
                                }
                            }
                            runOnUiThread {
                                pendingFlutterResult?.success("CONFIG_REQUIRED")
                                pendingFlutterResult = null
                            }
                        } else {
                            isInitialized = false
                            val errMsg = status.message ?: "Init failed"
                            Log.e("Verifone", "$errMsg (${status.status})")
                            runOnUiThread {
                                showToast(errMsg)
                                pendingFlutterResult?.error("INIT_FAILED", errMsg, status.status.toString())
                                pendingFlutterResult = null
                            }
                        }
                    } else if (status.type == Status.STATUS_TEARDOWN) {
                        isInitialized = false
                        transactionManager = null
                        Log.d("Verifone", "PSDK Teardown complete")
                    }
                } catch (e: Exception) {
                    Log.e("Verifone", "Error in handleStatus", e)
                    runOnUiThread {
                        pendingFlutterResult?.error("INIT_ERROR", e.localizedMessage, null)
                        pendingFlutterResult = null
                    }
                }
            }

            override fun handleTransactionEvent(event: TransactionEvent) {
                try {
                    Log.d("Verifone", "TxEvent: type=${event.type}, status=${event.status}")
                    // Track login/session state
                } catch (e: Exception) {
                    Log.e("Verifone", "Error in handleTransactionEvent", e)
                }
            }

            override fun handlePaymentCompletedEvent(event: PaymentCompletedEvent) {
                try {
                    Log.d("Verifone", "PaymentCompleted: status=${event.status}, msg=${event.message}")
                    pendingTransactionLock.set(false)
                    endSessionQuietly()
                } catch (e: Exception) {
                    Log.e("Verifone", "Error in handlePaymentCompletedEvent", e)
                    pendingTransactionLock.set(false)
                }
            }
        }
    }

    // ── FLUTTER BRIDGE ──────────────────────────────────────────────────────

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        createCommerceListener()

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
                        "displayConfig" -> {
                            displayVerifoneConfig(result)
                        }
                        "disconnect" -> {
                            disconnectTerminal(result)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Throwable) {
                    Log.e("Verifone", "MethodChannel error", e)
                    showToast("System Error: ${e.localizedMessage}")
                    try { result.error("UNEXPECTED_ERROR", e.localizedMessage, null) } catch (_: Exception) {}
                }
            }
    }

    // ================================================================
    // DISPLAY CONFIGURATION (P630 pairing screen)
    // ================================================================

    private fun displayVerifoneConfig(flutterResult: MethodChannel.Result) {
        runOnUiThread {
            try {
                if (paymentSdk == null) {
                    paymentSdk = PaymentSdk.create(this)
                }
                paymentSdk?.displayConfiguration(commerceListener, this)
                showToast("Select P630 terminal from the list")
                flutterResult.success("DISPLAYING_CONFIG")
            } catch (e: Exception) {
                Log.e("Verifone", "displayConfiguration failed", e)
                flutterResult.error("CONFIG_ERROR", e.localizedMessage, null)
            }
        }
    }

    // ================================================================
    // INITIALIZATION (matching reference app initializeWithIpAddress)
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
        pendingFlutterResult = flutterResult

        psdkScope.launch {
            try {
                // Create PaymentSdk ONCE (matches reference app: val paymentSdk = PaymentSdk.create(context))
                if (paymentSdk == null) {
                    paymentSdk = PaymentSdk.create(this@MainActivity)
                    Log.d("Verifone", "PaymentSdk created")
                }

                // Build TCP/IP config (matches reference app line 132-134)
                val config: HashMap<String, String> = hashMapOf(
                    PsdkDeviceInformation.DEVICE_ADDRESS_KEY to terminalIpAddress,
                    PsdkDeviceInformation.DEVICE_CONNECTION_TYPE_KEY to "tcpip"
                )

                // initializeFromValues (matches reference app line 139)
                paymentSdk?.initializeFromValues(commerceListener, config)
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
                // Matches reference app line 61: LoginCredentials.createWith2("username", "password", "shift", null)
                val credentials = LoginCredentials.createWith2("username", null, null, null)
                tm.loginWithCredentials(credentials)
                Log.i("Verifone", "Login request sent")
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
                    runOnUiThread {
                        flutterResult.error("NOT_CONNECTED",
                            "Terminal not connected. Call configureTerminal first.", null)
                    }
                    pendingTransactionLock.set(false)
                    return@launch
                }

                // Open session if needed (matches reference app line 138-143)
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
                        pendingTransactionLock.set(false)
                        return@launch
                    }
                }

                // Build payment (matches reference app line 518-529)
                val payment = Payment.create()
                payment.transactionType = TransactionType.PAYMENT
                payment.currency = currency

                val amounts = AmountTotals.create(true)
                try {
                    amounts.total = Decimal.valueOf(java.math.BigDecimal(amount))
                } catch (e: Exception) {
                    Log.e("Verifone", "Decimal conversion failed", e)
                    runOnUiThread {
                        flutterResult.error("AMOUNT_ERROR", "Invalid amount: $amount", null)
                    }
                    pendingTransactionLock.set(false)
                    return@launch
                }
                payment.requestedAmounts = amounts

                Log.i("Verifone", "Starting payment: $amount $currency")
                showToast("Processing: $amount $currency...")

                // Create payment listener before starting payment
                val paymentListener = createPaymentListener(flutterResult)
                paymentSdk?.addListener(paymentListener)

                val startStatus = tm.startPayment(payment)
                if (startStatus.status != StatusCode.SUCCESS) {
                    val failMsg = startStatus.message ?: "Could not start payment"
                    Log.e("Verifone", "startPayment failed: $failMsg")
                    runOnUiThread {
                        flutterResult.error("START_FAILED", failMsg, startStatus.status.toString())
                    }
                    paymentSdk?.removeListener(paymentListener)
                    endSessionQuietly()
                    pendingTransactionLock.set(false)
                }

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

            override fun handlePaymentCompletedEvent(event: PaymentCompletedEvent) {
                try {
                    Log.d("Verifone", "PaymentCompleted: status=${event.status}")

                    paymentSdk?.removeListener(this)
                    pendingTransactionLock.set(false)

                    if (event.status == StatusCode.SUCCESS) {
                        val payment = event.payment
                        val authResult = payment?.authResult

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
                    Log.d("Verifone", "Payment Status: code=${status.status}, msg=${status.message}")
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