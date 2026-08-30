package com.example.betalia_cashier

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import com.verifone.payment_sdk.*
import id.flutter.flutter_background_service.FlutterBackgroundServicePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import org.json.JSONObject
import java.math.BigDecimal
import java.util.concurrent.atomic.AtomicBoolean

@Suppress("DEPRECATION")
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "Verifone"
        private const val CHANNEL_NAME = "com.betalia.payments/p630"
        private const val POWER_MANAGEMENT_CHANNEL_NAME = "com.betalia.notifications/power"
        private const val DEFAULT_INSTANCE_ID = "counter-terminal"
        private const val LOGIN_TIMEOUT_MS = 30_000L
        private const val SESSION_TIMEOUT_MS = 15_000L
    }

    private data class TerminalConfig(
        val ipAddress: String,
        val serialNumber: String,
        val instanceId: String,
        val posDeviceId: String
    )

    private var paymentSdk: PaymentSdk? = null
    private var transactionManager: TransactionManager? = null
    private lateinit var commerceListener: CommerceListenerAdapter

    private var activeConfig: TerminalConfig? = null
    private var currentInstanceId: String? = null
    private var connectedSerialNumber: String? = null

    private var isInitializing = false
    private var isInitialized = false
    private var isLoggedIn = false
    private var isSessionOpen = false
    private var isTeardownInProgress = false

    private val paymentLock = AtomicBoolean(false)

    private var configureResult: MethodChannel.Result? = null
    private var activePaymentResult: MethodChannel.Result? = null
    private var activePaymentListener: CommerceListenerAdapter? = null

    private var afterTeardown: (() -> Unit)? = null
    private var teardownErrorHandler: ((String) -> Unit)? = null

    private var loginJob: Job? = null
    private var initTimeoutJob: Job? = null

    private val exceptionHandler = CoroutineExceptionHandler { _, throwable ->
        Log.e(TAG, "Unhandled coroutine error", throwable)
        paymentLock.set(false)
        isSessionOpen = false

        completeConfigureError(
            "INTERNAL_ERROR",
            throwable.localizedMessage ?: "Unknown internal error"
        )
        completePaymentError(
            "INTERNAL_ERROR",
            throwable.localizedMessage ?: "Unknown internal error"
        )
    }

    private val psdkScope = CoroutineScope(
        Dispatchers.IO + SupervisorJob() + exceptionHandler
    )

    // ---------------------------------------------------------------------
    // Flutter bridge
    // ---------------------------------------------------------------------

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        createCommerceListener()

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            POWER_MANAGEMENT_CHANNEL_NAME
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }

                    "requestIgnoreBatteryOptimizations" -> {
                        result.success(requestIgnoreBatteryOptimizations())
                    }

                    else -> result.notImplemented()
                }
            } catch (throwable: Throwable) {
                Log.e(TAG, "Power-management MethodChannel error", throwable)
                result.error(
                    "POWER_MANAGEMENT_ERROR",
                    throwable.localizedMessage ?: "Unable to open battery settings",
                    null
                )
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "configureTerminal" -> {
                        val ipAddress =
                            call.argument<String>("ipAddress")?.trim().orEmpty()

                        val serialNumber =
                            call.argument<String>("serialNumber")?.trim().orEmpty()

                        val instanceId =
                            call.argument<String>("instanceId")
                                ?.trim()
                                ?.takeIf { it.isNotEmpty() }
                                ?: DEFAULT_INSTANCE_ID

                        val posDeviceId =
                            call.argument<String>("posDeviceId")
                                ?.trim()
                                ?.takeIf { it.isNotEmpty() }
                                ?: "BETALIA_POS_$instanceId"

                        configureTerminal(
                            TerminalConfig(
                                ipAddress = ipAddress,
                                serialNumber = serialNumber,
                                instanceId = instanceId,
                                posDeviceId = posDeviceId
                            ),
                            result
                        )
                    }

                    "startTransaction" -> {
                        val amount = call.argument<Double>("amount") ?: 0.0
                        val currency =
                            call.argument<String>("currency")
                                ?.trim()
                                ?.takeIf { it.isNotEmpty() }
                                ?: "NOK"

                        startTransaction(amount, currency, result)
                    }

                    "checkTerminalStatus" -> checkTerminalStatus(result)
                    "endSession" -> endSession(result)
                    "displayConfig" -> displayConfig(result)
                    "disconnect" -> disconnect(result)
                    "forgetTerminal" -> forgetTerminal(result)
                    else -> result.notImplemented()
                }
            } catch (throwable: Throwable) {
                Log.e(TAG, "MethodChannel error", throwable)
                result.error(
                    "UNEXPECTED_ERROR",
                    throwable.localizedMessage ?: "Unexpected error",
                    null
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        sendCashierAppLifecycle(true)
    }

    override fun onPause() {
        sendCashierAppLifecycle(false)
        super.onPause()
    }

    override fun onStop() {
        sendCashierAppLifecycle(false)
        super.onStop()
    }

    private fun sendCashierAppLifecycle(isForeground: Boolean) {
        try {
            val servicePipe = FlutterBackgroundServicePlugin.servicePipe
            if (!servicePipe.hasListener()) return

            val payload = JSONObject().apply {
                put("method", "appLifecycle")
                put("args", JSONObject().put("isForeground", isForeground))
            }
            servicePipe.invoke(payload)
        } catch (throwable: Throwable) {
            Log.w(TAG, "Unable to update notification-service lifecycle", throwable)
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (isIgnoringBatteryOptimizations()) return true

        val packageUri = Uri.parse("package:$packageName")
        return try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = packageUri
                }
            )
            true
        } catch (directRequestError: Exception) {
            Log.w(TAG, "Direct battery exemption prompt unavailable", directRequestError)
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            true
        }
    }

    // ---------------------------------------------------------------------
    // Main PSDK listener
    // ---------------------------------------------------------------------

    private fun createCommerceListener() {
        commerceListener = object : CommerceListenerAdapter() {

            override fun handleStatus(status: Status) {
                Log.d(
                    TAG,
                    "Status: type=${status.type}, code=${status.status}, " +
                        "message=${status.message}"
                )

                try {
                    when (status.type) {
                        Status.STATUS_INITIALIZED -> handleInitializedStatus(status)
                        Status.STATUS_TEARDOWN -> handleTeardownStatus(status)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Status callback failed", e)
                    completeConfigureError(
                        "STATUS_ERROR",
                        e.localizedMessage ?: "PSDK status handling failed"
                    )
                }
            }

            override fun handleTransactionEvent(event: TransactionEvent) {
                Log.d(
                    TAG,
                    "TransactionEvent: type=${event.type}, status=${event.status}"
                )
                handleConnectionFailure(event.status)
            }

            override fun handleNotificationEvent(event: NotificationEvent) {
                Log.d(
                    TAG,
                    "NotificationEvent: type=${event.type}, status=${event.status}"
                )
                handleConnectionFailure(event.status)
            }

            // Payment completion is handled by a temporary per-payment listener.
            override fun handlePaymentCompletedEvent(event: PaymentCompletedEvent) {
                Log.d(TAG, "Global PaymentCompletedEvent: ${event.status}")
            }
        }
    }

    private fun handleInitializedStatus(status: Status) {
        initTimeoutJob?.cancel()
        initTimeoutJob = null
        isInitializing = false

        when (status.status) {
            StatusCode.SUCCESS -> {
                transactionManager = paymentSdk?.transactionManager

                if (transactionManager == null) {
                    resetRuntimeState()
                    completeConfigureError(
                        "NO_TRANSACTION_MANAGER",
                        "PSDK initialized but TransactionManager is unavailable"
                    )
                    return
                }

                isInitialized = true
                isLoggedIn = false
                loginToTerminal()
            }

            StatusCode.CONFIGURATION_REQUIRED -> {
                resetRuntimeState()
                runOnUiThread {
                    try {
                        paymentSdk?.displayConfiguration(
                            commerceListener,
                            this@MainActivity
                        )
                        showToast("Select the Verifone terminal")
                    } catch (e: Exception) {
                        Log.e(TAG, "displayConfiguration failed", e)
                    }
                }
                completeConfigureSuccess("CONFIG_REQUIRED")
            }

            StatusCode.CACHED_CONFIGURATION_MISMATCH -> {
                Log.w(TAG, "Cached configuration mismatch; clearing saved terminal")
                recoverFromCachedMismatch()
            }

            else -> {
                resetRuntimeState()
                completeConfigureError(
                    "INIT_FAILED",
                    status.message ?: "Terminal initialization failed",
                    status.status.toString()
                )
            }
        }
    }

    private fun handleTeardownStatus(status: Status) {
        isTeardownInProgress = false

        if (status.status != StatusCode.SUCCESS) {
            val message = status.message ?: "PSDK teardown failed"
            val onError = teardownErrorHandler

            afterTeardown = null
            teardownErrorHandler = null
            onError?.invoke(message)
            return
        }

        loginJob?.cancel()
        initTimeoutJob?.cancel()
        loginJob = null
        initTimeoutJob = null

        resetRuntimeState()
        transactionManager = null

        val action = afterTeardown
        afterTeardown = null
        teardownErrorHandler = null
        action?.invoke()
    }

    // ---------------------------------------------------------------------
    // Configure and connect
    // ---------------------------------------------------------------------

    private fun configureTerminal(
        requested: TerminalConfig,
        result: MethodChannel.Result
    ) {
        if (requested.ipAddress.isBlank()) {
            result.error("INVALID_IP", "Terminal IP address is required", null)
            return
        }

        if (requested.serialNumber.isBlank()) {
            result.error(
                "INVALID_SERIAL",
                "Terminal serial number is required",
                null
            )
            return
        }

        if (configureResult != null || isInitializing || isTeardownInProgress) {
            result.error(
                "CONFIGURATION_BUSY",
                "A terminal configuration operation is already in progress",
                null
            )
            return
        }

        if (paymentLock.get()) {
            result.error(
                "PAYMENT_BUSY",
                "Cannot change the terminal during a payment",
                null
            )
            return
        }

        configureResult = result

        val oldConfig = activeConfig
        val instanceChanged =
            currentInstanceId != null && currentInstanceId != requested.instanceId

        val serialChangedOnSameInstance =
            oldConfig != null &&
                oldConfig.instanceId == requested.instanceId &&
                !oldConfig.serialNumber.equals(
                    requested.serialNumber,
                    ignoreCase = true
                )

        if (
            isInitialized &&
            isLoggedIn &&
            oldConfig != null &&
            oldConfig.instanceId == requested.instanceId &&
            oldConfig.serialNumber.equals(
                requested.serialNumber,
                ignoreCase = true
            )
        ) {
            activeConfig = requested
            completeConfigureSuccess("CONNECTED")
            return
        }

        if (paymentSdk != null && (instanceChanged || serialChangedOnSameInstance)) {
            val oldDevice = paymentSdk?.deviceInformation

            teardownThen(
                onSuccess = {
                    try {
                        if (serialChangedOnSameInstance && oldDevice != null) {
                            // Clear the old saved terminal before replacing it.
                            paymentSdk?.UseDevice(oldDevice, false)
                        }

                        if (instanceChanged) {
                            paymentSdk = null
                            currentInstanceId = null
                        }

                        activeConfig = requested
                        ensurePaymentSdk(requested.instanceId)
                        initializeFromValues(requested)
                    } catch (e: Exception) {
                        completeConfigureError(
                            "RECONFIGURE_ERROR",
                            e.localizedMessage ?: "Could not change terminal"
                        )
                    }
                },
                onError = { message ->
                    completeConfigureError("TEARDOWN_FAILED", message)
                }
            )
            return
        }

        activeConfig = requested
        ensurePaymentSdk(requested.instanceId)
        initializeFromValues(requested)
    }

    private fun ensurePaymentSdk(instanceId: String) {
        if (paymentSdk != null && currentInstanceId == instanceId) {
            return
        }

        paymentSdk = PaymentSdk.createWithInstanceId(
            this@MainActivity,
            instanceId
        )
        currentInstanceId = instanceId

        Log.i(TAG, "Created PaymentSdk instance: $instanceId")
    }

    private fun initializeFromValues(config: TerminalConfig) {
        val sdk = paymentSdk ?: run {
            completeConfigureError("NO_PSDK", "PaymentSdk is unavailable")
            return
        }

        isInitializing = true
        isInitialized = false
        isLoggedIn = false
        connectedSerialNumber = null

        val values = hashMapOf<String, String>(
            PsdkDeviceInformation.DEVICE_CONNECTION_TYPE_KEY to "tcpip",
            PsdkDeviceInformation.DEVICE_ADDRESS_KEY to config.ipAddress,

            // Restricts PSDK scanning/recovery to this physical terminal.
            PsdkDeviceInformation.DEVICE_SERIAL_NUMBER_KEY to
                config.serialNumber,

            // Identifies this POS device/application to the terminal.
            PosInformation.DEVICE_ID_KEY to config.posDeviceId,

            // If the IP changes, PSDK may scan the network but still has to
            // match DEVICE_SERIAL_NUMBER_KEY.
            PsdkInitializationConstants.NETWORK_CONFIGURATION_KEY to
                PsdkInitializationConstants.NETWORK_CONFIGURATION_DYNAMIC_VALUE
        )

        Log.i(
            TAG,
            "Connecting: ip=${config.ipAddress}, " +
                "serial=${config.serialNumber}, instance=${config.instanceId}"
        )

        try {
            sdk.initializeFromValues(commerceListener, values)
            startInitTimeout()
        } catch (e: Exception) {
            isInitializing = false
            completeConfigureError(
                "INIT_ERROR",
                e.localizedMessage ?: "Could not initialize PSDK"
            )
        }
    }

    private fun startInitTimeout() {
        initTimeoutJob?.cancel()
        initTimeoutJob = psdkScope.launch {
            delay(LOGIN_TIMEOUT_MS)

            if (isInitializing) {
                isInitializing = false
                completeConfigureError(
                    "INIT_TIMEOUT",
                    "Terminal initialization timed out"
                )
                try {
                    paymentSdk?.tearDown()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun recoverFromCachedMismatch() {
        val config = activeConfig
        val oldDevice = paymentSdk?.deviceInformation

        if (config == null) {
            completeConfigureError(
                "CACHE_MISMATCH",
                "Cached terminal configuration does not match"
            )
            return
        }

        teardownThen(
            onSuccess = {
                try {
                    if (oldDevice != null) {
                        paymentSdk?.UseDevice(oldDevice, false)
                    }
                    initializeFromValues(config)
                } catch (e: Exception) {
                    completeConfigureError(
                        "CACHE_RESET_FAILED",
                        e.localizedMessage ?: "Could not clear terminal cache"
                    )
                }
            },
            onError = { message ->
                completeConfigureError("TEARDOWN_FAILED", message)
            }
        )
    }

    // ---------------------------------------------------------------------
    // Login and verify the connected terminal
    // ---------------------------------------------------------------------

    private fun loginToTerminal() {
        loginJob?.cancel()

        loginJob = psdkScope.launch {
            try {
                val tm = transactionManager ?: run {
                    completeConfigureError(
                        "NO_TRANSACTION_MANAGER",
                        "TransactionManager is unavailable"
                    )
                    return@launch
                }

                val credentials = LoginCredentials.createWith2(
                    "username",
                    null,
                    null,
                    null
                )

                val loginStatus = tm.loginWithCredentials(credentials)

                if (loginStatus.status != StatusCode.SUCCESS) {
                    completeConfigureError(
                        "LOGIN_FAILED",
                        loginStatus.message ?: "Terminal login failed",
                        loginStatus.status.toString()
                    )
                    return@launch
                }

                val loginCompleted = withTimeoutOrNull(LOGIN_TIMEOUT_MS) {
                    while (isActive) {
                        if (tm.state == TransactionManagerState.LOGGED_IN) {
                            return@withTimeoutOrNull true
                        }
                        delay(100)
                    }
                    false
                } ?: false

                if (!loginCompleted) {
                    isLoggedIn = false
                    completeConfigureError(
                        "LOGIN_TIMEOUT",
                        "Terminal login timed out"
                    )
                    return@launch
                }

                isLoggedIn = true

                if (!verifyConnectedSerial()) {
                    return@launch
                }

                completeConfigureSuccess("CONNECTED")
            } catch (e: Exception) {
                isLoggedIn = false
                completeConfigureError(
                    "LOGIN_ERROR",
                    e.localizedMessage ?: "Terminal login failed"
                )
            }
        }
    }

    private fun verifyConnectedSerial(): Boolean {
        val expected = activeConfig?.serialNumber
        val actual = paymentSdk
            ?.deviceInformation
            ?.serialNumber
            ?.trim()

        connectedSerialNumber = actual

        if (expected.isNullOrBlank()) {
            completeConfigureError(
                "EXPECTED_SERIAL_MISSING",
                "Expected terminal serial number is missing"
            )
            safeTeardown()
            return false
        }

        if (actual.isNullOrBlank()) {
            completeConfigureError(
                "SERIAL_UNAVAILABLE",
                "Connected terminal did not provide its serial number"
            )
            safeTeardown()
            return false
        }

        if (!actual.equals(expected, ignoreCase = true)) {
            completeConfigureError(
                "WRONG_TERMINAL",
                "Wrong terminal connected. Expected $expected, received $actual"
            )
            safeTeardown()
            return false
        }

        Log.i(TAG, "Correct terminal connected: serial=$actual")
        return true
    }

    // ---------------------------------------------------------------------
    // Payment
    // ---------------------------------------------------------------------

    private fun startTransaction(
        amount: Double,
        currency: String,
        result: MethodChannel.Result
    ) {
        if (amount <= 0.0) {
            result.error(
                "INVALID_AMOUNT",
                "Payment amount must be greater than zero",
                null
            )
            return
        }

        if (!isInitialized || !isLoggedIn || transactionManager == null) {
            result.error(
                "NOT_CONNECTED",
                "Terminal is not connected and logged in",
                null
            )
            return
        }

        if (!paymentLock.compareAndSet(false, true)) {
            result.error("BUSY", "A payment is already in progress", null)
            return
        }

        activePaymentResult = result

        psdkScope.launch {
            try {
                val tm = transactionManager ?: run {
                    completePaymentError(
                        "NOT_CONNECTED",
                        "TransactionManager is unavailable"
                    )
                    return@launch
                }

                if (!isSessionOpen && !openSession(tm, currency)) {
                    completePaymentError(
                        "SESSION_FAILED",
                        "Could not open a payment session"
                    )
                    return@launch
                }

                val payment = Payment.create().apply {
                    transactionType = TransactionType.PAYMENT
                    this.currency = currency
                    requestedAmounts = AmountTotals.create(true).apply {
                        total = Decimal.valueOf(BigDecimal.valueOf(amount))
                    }
                }

                val listener = createPaymentListener()
                activePaymentListener = listener
                paymentSdk?.addListener(listener)

                val startStatus = tm.startPayment(payment)

                if (startStatus.status != StatusCode.SUCCESS) {
                    paymentSdk?.removeListener(listener)
                    activePaymentListener = null
                    completePaymentError(
                        "START_FAILED",
                        startStatus.message ?: "Could not start payment",
                        startStatus.status.toString()
                    )
                    endSessionQuietly()
                }
            } catch (e: Exception) {
                completePaymentError(
                    "TX_ERROR",
                    e.localizedMessage ?: "Payment failed"
                )
                endSessionQuietly()
            }
        }
    }

    private suspend fun openSession(
        tm: TransactionManager,
        currency: String
    ): Boolean {
        return try {
            val transaction = Transaction.create().apply {
                this.currency = currency
            }

            val sessionStarted = tm.startSession2(transaction)

            if (!sessionStarted) {
                Log.e(TAG, "startSession2 failed")
                return false
            }

            val opened = withTimeoutOrNull(SESSION_TIMEOUT_MS) {
                while (isActive) {
                    if (tm.state == TransactionManagerState.SESSION_OPEN) {
                        return@withTimeoutOrNull true
                    }
                    delay(100)
                }
                false
            } ?: false

            isSessionOpen = opened
            opened
        } catch (e: Exception) {
            Log.e(TAG, "Could not open session", e)
            isSessionOpen = false
            false
        }
    }

    private fun createPaymentListener(): CommerceListenerAdapter {
        return object : CommerceListenerAdapter() {

            override fun handlePaymentCompletedEvent(event: PaymentCompletedEvent) {
                try {
                    paymentSdk?.removeListener(this)
                    activePaymentListener = null

                    if (event.status == StatusCode.SUCCESS) {
                        val payment = event.payment
                        val authorization = payment?.authResult

                        if (authorization == AuthorizationResult.AUTHORIZED) {
                            showToast("PAYMENT APPROVED")
                            completePaymentSuccess(
                                buildJsonResponse(
                                    status = "APPROVED",
                                    authResult = authorization.toString(),
                                    transactionId = payment.transactionId,
                                    rrn = payment.retrievalReferenceNumber
                                )
                            )
                        } else {
                            completePaymentSuccess(
                                buildJsonResponse(
                                    status = "COMPLETED",
                                    authResult =
                                        authorization?.toString() ?: "UNKNOWN",
                                    transactionId = payment?.transactionId,
                                    rrn = payment?.retrievalReferenceNumber
                                )
                            )
                        }
                    } else {
                        completePaymentError(
                            "PAYMENT_FAILED",
                            event.message ?: "Payment failed",
                            event.status.toString()
                        )
                    }
                } catch (e: Exception) {
                    completePaymentError(
                        "PAYMENT_HANDLER_ERROR",
                        e.localizedMessage ?: "Payment completion failed"
                    )
                } finally {
                    endSessionQuietly()
                }
            }

            override fun handleNotificationEvent(event: NotificationEvent) {
                handleConnectionFailure(event.status)
            }
        }
    }

    // ---------------------------------------------------------------------
    // Session, disconnect and forget
    // ---------------------------------------------------------------------

    private fun endSession(result: MethodChannel.Result) {
        psdkScope.launch {
            try {
                val tm = transactionManager ?: run {
                    runOnUiThread {
                        result.error("NOT_CONNECTED", "Terminal is not connected", null)
                    }
                    return@launch
                }

                tm.endSession()
                isSessionOpen = false
                runOnUiThread { result.success("SESSION_ENDED") }
            } catch (e: Exception) {
                runOnUiThread {
                    result.error(
                        "END_SESSION_ERROR",
                        e.localizedMessage ?: "Could not end session",
                        null
                    )
                }
            }
        }
    }

    private fun endSessionQuietly() {
        psdkScope.launch {
            try {
                if (isSessionOpen) {
                    transactionManager?.endSession()
                    isSessionOpen = false
                }
            } catch (e: Exception) {
                Log.e(TAG, "endSession failed", e)
            }
        }
    }

    private fun disconnect(result: MethodChannel.Result) {
        if (paymentLock.get()) {
            result.error(
                "PAYMENT_BUSY",
                "Cannot disconnect during a payment",
                null
            )
            return
        }

        psdkScope.launch {
            try {
                if (isSessionOpen) {
                    transactionManager?.endSession()
                    isSessionOpen = false
                    delay(200)
                }

                if (isLoggedIn) {
                    transactionManager?.logout()
                    isLoggedIn = false
                    delay(200)
                }

                // Normal disconnect preserves PSDK's persisted terminal record.
                teardownThen(
                    onSuccess = {
                        runOnUiThread { result.success("DISCONNECTED") }
                    },
                    onError = { message ->
                        runOnUiThread {
                            result.error("DISCONNECT_ERROR", message, null)
                        }
                    }
                )
            } catch (e: Exception) {
                runOnUiThread {
                    result.error(
                        "DISCONNECT_ERROR",
                        e.localizedMessage ?: "Could not disconnect",
                        null
                    )
                }
            }
        }
    }

    private fun forgetTerminal(result: MethodChannel.Result) {
        if (paymentLock.get()) {
            result.error(
                "PAYMENT_BUSY",
                "Cannot forget terminal during a payment",
                null
            )
            return
        }

        // If the SDK is still scanning/initializing, abort cleanly instead of
        // calling tearDown() — PSDK can crash when torn down mid-connection.
        if (isInitializing || isTeardownInProgress) {
            initTimeoutJob?.cancel()
            initTimeoutJob = null
            configureResult = null
            clearSavedTerminalState()
            result.success("TERMINAL_FORGOTTEN")
            return
        }

        val sdk = paymentSdk
        val deviceInfo = sdk?.deviceInformation

        if (sdk == null || deviceInfo == null) {
            clearSavedTerminalState()
            result.success("TERMINAL_FORGOTTEN")
            return
        }

        teardownThen(
            onSuccess = {
                try {
                    sdk.UseDevice(deviceInfo, false)
                    clearSavedTerminalState()
                    runOnUiThread { result.success("TERMINAL_FORGOTTEN") }
                } catch (e: Exception) {
                    runOnUiThread {
                        result.error(
                            "FORGET_ERROR",
                            e.localizedMessage ?: "Could not forget terminal",
                            null
                        )
                    }
                }
            },
            onError = { message ->
                runOnUiThread {
                    result.error("FORGET_ERROR", message, null)
                }
            }
        )
    }

    private fun clearSavedTerminalState() {
        resetRuntimeState()
        paymentSdk = null
        transactionManager = null
        activeConfig = null
        currentInstanceId = null
        connectedSerialNumber = null
    }

    private fun teardownThen(
        onSuccess: () -> Unit,
        onError: (String) -> Unit
    ) {
        if (isTeardownInProgress) {
            onError("A teardown operation is already in progress")
            return
        }

        val sdk = paymentSdk

        if (sdk == null) {
            resetRuntimeState()
            onSuccess()
            return
        }

        isTeardownInProgress = true
        afterTeardown = onSuccess
        teardownErrorHandler = onError

        try {
            sdk.tearDown()
        } catch (e: Exception) {
            isTeardownInProgress = false
            afterTeardown = null
            teardownErrorHandler = null
            onError(e.localizedMessage ?: "PSDK teardown failed")
        }
    }

    private fun safeTeardown() {
        if (isTeardownInProgress) return

        isTeardownInProgress = true
        afterTeardown = null
        teardownErrorHandler = null

        try {
            paymentSdk?.tearDown()
        } catch (e: Exception) {
            isTeardownInProgress = false
            Log.e(TAG, "Safe teardown failed", e)
        }
    }

    // ---------------------------------------------------------------------
    // Manual Verifone configuration screen
    // ---------------------------------------------------------------------

    private fun displayConfig(result: MethodChannel.Result) {
        runOnUiThread {
            try {
                ensurePaymentSdk(activeConfig?.instanceId ?: DEFAULT_INSTANCE_ID)
                paymentSdk?.displayConfiguration(commerceListener, this)
                showToast("Select the Verifone terminal")
                result.success("DISPLAYING_CONFIG")
            } catch (e: Exception) {
                result.error(
                    "CONFIG_ERROR",
                    e.localizedMessage ?: "Could not display configuration",
                    null
                )
            }
        }
    }

    // ---------------------------------------------------------------------
    // Connection errors and status
    // ---------------------------------------------------------------------

    private fun handleConnectionFailure(statusCode: Int) {
        when (statusCode) {
            StatusCode.DEVICE_CONNECTION_LOST,
            StatusCode.DEVICE_CONNECTION_FAILED,
            StatusCode.DEVICE_ERROR,
            StatusCode.DEVICE_REJECTED_PAIRING -> {
                resetRuntimeState()
                completePaymentError(
                    "DEVICE_CONNECTION_LOST",
                    "Connection to the payment terminal was lost",
                    statusCode.toString()
                )
                safeTeardown()
            }
        }
    }

    private fun checkTerminalStatus(result: MethodChannel.Result) {
        try {
            val connected =
                isInitialized &&
                    isLoggedIn &&
                    paymentSdk != null &&
                    transactionManager != null

            result.success(
                buildJsonResponse(
                    status = if (connected) "CONNECTED" else "NOT_CONNECTED",
                    authResult = null,
                    transactionId = null,
                    rrn = null
                ) {
                    put("ipAddress", activeConfig?.ipAddress)
                    put("instanceId", activeConfig?.instanceId)
                    put("expectedSerialNumber", activeConfig?.serialNumber)
                    put("connectedSerialNumber", connectedSerialNumber)
                    put("isInitializing", isInitializing)
                    put("isInitialized", isInitialized)
                    put("isLoggedIn", isLoggedIn)
                    put("isSessionOpen", isSessionOpen)
                    put(
                        "transactionManagerState",
                        transactionManager?.state?.toString()
                    )
                }
            )
        } catch (e: Exception) {
            result.error(
                "STATUS_ERROR",
                e.localizedMessage ?: "Could not read terminal status",
                null
            )
        }
    }

    // ---------------------------------------------------------------------
    // Flutter result helpers
    // ---------------------------------------------------------------------

    private fun completeConfigureSuccess(value: String) {
        val result = configureResult ?: return
        configureResult = null
        runOnUiThread { result.success(value) }
    }

    private fun completeConfigureError(
        code: String,
        message: String,
        details: String? = null
    ) {
        val result = configureResult ?: return
        configureResult = null
        runOnUiThread { result.error(code, message, details) }
    }

    private fun completePaymentSuccess(value: String) {
        val result = activePaymentResult ?: return
        activePaymentResult = null
        paymentLock.set(false)
        runOnUiThread { result.success(value) }
    }

    private fun completePaymentError(
        code: String,
        message: String,
        details: String? = null
    ) {
        val result = activePaymentResult
        activePaymentResult = null
        paymentLock.set(false)

        activePaymentListener?.let { listener ->
            try {
                paymentSdk?.removeListener(listener)
            } catch (_: Exception) {
            }
        }
        activePaymentListener = null

        if (result != null) {
            runOnUiThread { result.error(code, message, details) }
        }
    }

    // ---------------------------------------------------------------------
    // Utilities
    // ---------------------------------------------------------------------

    private fun resetRuntimeState() {
        isInitializing = false
        isInitialized = false
        isLoggedIn = false
        isSessionOpen = false
        connectedSerialNumber = null
    }

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
                Log.e(TAG, "Could not show error dialog", e)
            }
        }
    }

    override fun onDestroy() {
        loginJob?.cancel()
        initTimeoutJob?.cancel()

        try {
            activePaymentListener?.let { paymentSdk?.removeListener(it) }
        } catch (_: Exception) {
        }

        try {
            paymentSdk?.tearDown()
        } catch (_: Exception) {
        }

        psdkScope.cancel()
        super.onDestroy()
    }
}
