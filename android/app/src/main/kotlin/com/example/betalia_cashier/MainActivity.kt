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

    // State tracking
    private var isInitialized = false
    private var isLoggedIn = false
    private var isSessionOpen = false
    private var terminalIpAddress: String = ""
    private var pendingTransactionLock = AtomicBoolean(false)

    // Coroutine exception handler — catches all unhandled coroutine crashes
    private val exceptionHandler = CoroutineExceptionHandler { _, throwable ->
        Log.e("Verifone", "Unhandled coroutine exception", throwable)
        showToast("Internal Error: ${throwable.localizedMessage}")
        showNativeErrorDialog("App Error", "Internal: ${throwable.localizedMessage}")
        // Reset state to allow recovery
        pendingTransactionLock.set(false)
        isSessionOpen = false
    }

    // Coroutine scope for background PSDK operations
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
                    try {
                        result.error("UNEXPECTED_ERROR", e.localizedMessage, null)
                    } catch (_: Exception) {}
                }
            }
    }

    // ================================================================
    // PSDK INITIALIZATION & CONNECTION
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
                // If previously initialized, tear down first
                if (paymentSdk != null) {
                    Log.d("Verifone", "Tearing down previous SDK instance...")
                    paymentSdk?.tearDown()
                    delay(500)
                }

                // Step 1: Create PaymentSdk
                paymentSdk = PaymentSdk.create(this@MainActivity)
                Log.d("Verifone", "PaymentSdk created")

                // Step 2: Build connection params for TCP/IP client mode
                val paramMap: HashMap<String, String> = hashMapOf(
                    PsdkDeviceInformation.DEVICE_CONNECTION_TYPE_KEY to "tcpip",
                    PsdkDeviceInformation.DEVICE_ADDRESS_KEY to terminalIpAddress
                )

                // Add port if specified (default P630 port is typically 16101 or 8082)
                if (port.isNotBlank()) {
                    paramMap[TransactionManager.DEVICE_PORT_KEY] = port.trim()
                }

                // Step 3: Create the commerce listener
                val initListener = object : CommerceListenerAdapter() {
                    override fun handleStatus(status: Status) {
                        Log.d("Verifone", "Initialize status: code=${status.getStatus()}, msg=${status.getMessage()}")
                        if (status.getStatus() == StatusCode.SUCCESS) {
                            isInitialized = true
                            Log.i("Verifone", "PSDK Initialized successfully!")

                            // Step 4: Get TransactionManager
                            transactionManager = paymentSdk?.getTransactionManager()
                            Log.d("Verifone", "TransactionManager obtained: ${transactionManager != null}")

                            // Step 5: Login
                            loginToTerminal()

                            runOnUiThread {
                                showToast("Verifone Terminal Connected")
                                flutterResult.success("CONNECTED")
                            }
                        } else {
                            isInitialized = false
                            val errMsg = "Init failed: ${status.getMessage()} (${status.getStatus()})"
                            Log.e("Verifone", errMsg)
                            runOnUiThread {
                                showToast(errMsg)
                                flutterResult.error("INIT_FAILED", status.getMessage(), status.getStatus().toString())
                            }
                        }
                    }
                }

                // Register listener first, then initialize
                paymentSdk?.addListener(initListener)
                paymentSdk?.initializeFromValues(initListener, paramMap)
                Log.d("Verifone", "initializeFromValues called with IP: $terminalIpAddress")

            } catch (e: Exception) {
                Log.e("Verifone", "Failed to initialize PSDK", e)
                runOnUiThread {
                    showToast("Initialize Error: ${e.localizedMessage}")
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
                val tm = transactionManager
                if (tm == null) {
                    Log.e("Verifone", "Cannot login - TransactionManager is null")
                    return@launch
                }

                // Use empty credentials - the PSDK docs say username/password are optional
                val credentials = LoginCredentials.createWith2(null, null, null, null)
                val status = tm.loginWithCredentials(credentials)

                if (status.getStatus() == StatusCode.SUCCESS) {
                    Log.i("Verifone", "Login request sent successfully")
                    // LOGIN_COMPLETED will come via the commerce listener
                } else {
                    Log.e("Verifone", "Login request failed: ${status.getMessage()}")
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

    private fun startVerifoneSession() {
        psdkScope.launch {
            try {
                val tm = transactionManager ?: return@launch
                val transaction = Transaction.create()
                val status = tm.startSession2(transaction)

                if (status) {
                    Log.i("Verifone", "StartSession2 request sent successfully")
                    // TRANSACTION_STARTED event will come via the commerce listener
                } else {
                    Log.e("Verifone", "StartSession2 failed")
                    showToast("Session start failed")
                }
            } catch (e: Exception) {
                Log.e("Verifone", "Start session exception", e)
            }
        }
    }

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
                    Log.e("Verifone", "No TransactionManager - need to initialize first")
                    runOnUiThread {
                        flutterResult.error("NOT_CONNECTED", "Terminal not connected. Call configureTerminal first.", null)
                    }
                    pendingTransactionLock.set(false)
                    return@launch
                }

                // Ensure listener is set for payment events
                val paymentListener = createPaymentListener(flutterResult)
                paymentSdk?.addListener(paymentListener)

                // Open session if not already open
                if (!isSessionOpen) {
                    Log.d("Verifone", "Session not open, starting session...")
                    val txn = Transaction.create()
                    txn.currency = currency
                    val sessionStatus = tm.startSession2(txn)
                    if (!sessionStatus) {
                        val errMsg = "Failed to start session"
                        Log.e("Verifone", "Session start failed: $errMsg")
                        runOnUiThread {
                            flutterResult.error("SESSION_FAILED", errMsg, null)
                        }
                        paymentSdk?.removeListener(paymentListener)
                        pendingTransactionLock.set(false)
                        return@launch
                    }
                    // Brief delay for session to open
                    delay(1000)
                }

                // Build the Payment object
                val payment = Payment.create()
                payment.transactionType = TransactionType.PAYMENT
                payment.currency = currency

                val amounts = AmountTotals.create(true)

                // Convert to Decimal properly - avoid floating point issues
                // PSDK Decimal uses value*100 + scale of 2 for typical currency
                val cents = Math.round(amount * 100.0)
                val decAmount = Decimal(cents.toDouble() / 100.0)
                amounts.total = decAmount
                payment.requestedAmounts = amounts

                Log.i("Verifone", "Starting payment: $amount $currency (${cents} cents)")
                showToast("Processing payment: $amount $currency...")

                val startStatus = tm.startPayment(payment)

                if (startStatus.getStatus() != StatusCode.SUCCESS) {
                    val failMsg = startStatus.getMessage() ?: "Could not start payment"
                    Log.e("Verifone", "startPayment failed: $failMsg")
                    runOnUiThread {
                        showToast("Payment Failed: $failMsg")
                        flutterResult.error("START_FAILED", failMsg, startStatus.getStatus().toString())
                    }
                    paymentSdk?.removeListener(paymentListener)
                    endSessionQuietly()
                    pendingTransactionLock.set(false)
                    return@launch
                }

                Log.d("Verifone", "startPayment sent successfully, awaiting result...")

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
                Log.d("Verifone", "Transaction event: ${event.getType()}, status: ${event.getStatus()}")

                when (event.getType()) {
                    TransactionEvent.LOGIN_COMPLETED -> {
                        if (event.getStatus() == StatusCode.SUCCESS) {
                            isLoggedIn = true
                            Log.i("Verifone", "Login completed successfully")
                            showToast("Login Successful")
                        } else {
                            Log.w("Verifone", "Login failed: ${event.getMessage()}")
                            showToast("Login failed: ${event.getMessage()}")
                        }
                    }
                    TransactionEvent.TRANSACTION_STARTED -> {
                        if (event.getStatus() == StatusCode.SUCCESS) {
                            isSessionOpen = true
                            Log.i("Verifone", "Session started successfully")
                            showToast("Session Started")
                        } else {
                            Log.w("Verifone", "Session start failed: ${event.getMessage()}")
                            showToast("Session start failed: ${event.getMessage()}")
                        }
                    }
                    TransactionEvent.TRANSACTION_ENDED -> {
                        isSessionOpen = false
                        Log.d("Verifone", "Session ended")
                        showToast("Session Ended")
                    }
                    TransactionEvent.LOGOUT_COMPLETED -> {
                        isLoggedIn = false
                        Log.d("Verifone", "Logout completed")
                        showToast("Logout Completed")
                    }
                }
            }

            override fun handlePaymentCompletedEvent(event: PaymentCompletedEvent) {
                Log.d("Verifone", "PaymentCompleted: status=${event.getStatus()}, type=${event.getType()}")

                paymentSdk?.removeListener(this)
                pendingTransactionLock.set(false)

                if (event.getStatus() == StatusCode.SUCCESS) {
                    val payment = event.getPayment()
                    val authResult = payment?.getAuthResult()

                    Log.i("Verifone", "Payment successful. AuthResult: $authResult")

                    if (authResult == AuthorizationResult.AUTHORIZED) {
                        runOnUiThread {
                            showToast("PAYMENT APPROVED ✓")
                            flutterResult.success(
                                buildJsonResponse(
                                    "APPROVED",
                                    authResult.toString(),
                                    payment?.getTransactionId(),
                                    payment?.getRetrievalReferenceNumber()
                                )
                            )
                        }
                    } else if (authResult == AuthorizationResult.DECLINED) {
                        val declineMsg = payment?.getAuthResponseText() ?: "Transaction Declined"
                        runOnUiThread {
                            showToast("DECLINED: $declineMsg")
                            flutterResult.error("DECLINED", declineMsg, "DECLINED")
                        }
                    } else {
                        // Other results: IN_PROGRESS, CANCELLED, etc.
                        val resultMsg = "Auth Result: $authResult"
                        runOnUiThread {
                            showToast(resultMsg)
                            flutterResult.success(buildJsonResponse("COMPLETED", authResult.toString(), null, null))
                        }
                    }

                    // End session after payment completes
                    endSessionQuietly()

                } else {
                    val errorMsg = event.getMessage() ?: "Payment failed"
                    Log.e("Verifone", "Payment failed: $errorMsg (${event.getStatus()})")
                    runOnUiThread {
                        showToast("Payment Error: $errorMsg")
                        flutterResult.error("PAYMENT_FAILED", errorMsg, event.getStatus().toString())
                    }
                    endSessionQuietly()
                }
            }

            override fun handleStatus(status: Status) {
                Log.d("Verifone", "SDK Status: code=${status.getStatus()}, msg=${status.getMessage()}")
                if (status.getStatus() != StatusCode.SUCCESS && status.getStatus() != 0) {
                    Log.w("Verifone", "Non-success status: ${status.getMessage()}")
                }
            }
        }
    }

    private fun endSessionQuietly() {
        psdkScope.launch {
            try {
                delay(500) // Brief delay to allow completion events
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
            if (!isInitialized || paymentSdk == null) {
                result.success(buildJsonResponse("NOT_CONNECTED", null, null, null))
                return
            }

            val deviceInfo = paymentSdk?.getDeviceInformation()
            val state = deviceInfo?.getState()

            val statusStr = when (state) {
                PaymentDeviceState.CONNECTED -> "CONNECTED"
                PaymentDeviceState.CONNECTING -> "CONNECTING"
                PaymentDeviceState.NOT_CONNECTED -> "NOT_CONNECTED"
                PaymentDeviceState.CONNECTION_LOST -> "CONNECTION_LOST"
                PaymentDeviceState.DISCONNECTING -> "DISCONNECTING"
                PaymentDeviceState.MAINTENANCE_IN_PROGRESS -> "MAINTENANCE"
                else -> "UNKNOWN"
            }

            val ip = deviceInfo?.getAddress() ?: terminalIpAddress
            val serial = deviceInfo?.getSerialNumber() ?: ""

            result.success(
                buildJsonResponse(statusStr, null, null, null) {
                    put("ipAddress", ip)
                    put("serialNumber", serial)
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
    // UTILITY METHODS
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
        try {
            paymentSdk?.tearDown()
        } catch (_: Exception) {}
        super.onDestroy()
    }
}