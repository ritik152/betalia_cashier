package com.example.betalia_cashier

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log
import android.widget.Toast
import java.util.concurrent.atomic.AtomicBoolean
import androidx.appcompat.app.AlertDialog

// Verifone PSDK Imports
import com.verifone.payment_sdk.*

class MainActivity: FlutterActivity() {
    private val channelName = "com.betalia.payments/p630"
    private var paymentSdk: PaymentSdk? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            try {
                // Use AtomicBoolean to ensure we only reply to Flutter once per call
                val resultSent = AtomicBoolean(false)

                when (call.method) {
                    "startTransaction" -> {
                        val amount = call.argument<Int>("amountInCents") ?: 5
                        val currency = call.argument<String>("currency") ?: "NOK"
                        runVerifoneTransaction(amount, currency, result, resultSent)
                    }
                    "checkTerminalStatus" -> {
                        checkStatus(result)
                    }
                    "openConfig" -> {
                        try {
                            val sdk = getSdk()
                            sdk?.displayConfiguration(object : CommerceListenerAdapter() {}, this)
                            showToast("Opening Verifone Configuration...")
                            result.success("OPENED")
                        } catch (e: Exception) {
                            Log.e("Verifone", "Failed to open config", e)
                            showToast("Config Error: ${e.localizedMessage}")
                            result.error("CONFIG_ERROR", e.localizedMessage, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                Log.e("Verifone", "Unexpected error in MethodChannel handler", e)
                showToast("System Error: ${e.localizedMessage}")
                showNativeErrorDialog("System Error", "An unexpected error occurred: ${e.localizedMessage}")
                try { result.error("UNEXPECTED_ERROR", e.localizedMessage, null) } catch (ignored: Exception) {}
            }
        }
    }

    /**
     * Safely gets or initializes the PaymentSdk.
     */
    private fun getSdk(): PaymentSdk? {
        return try {
            if (paymentSdk == null) {
                paymentSdk = PaymentSdk.create(this)
            }
            paymentSdk
        } catch (e: Exception) {
            Log.e("Verifone", "Failed to initialize PaymentSdk", e)
            null
        }
    }

    /**
     * Shows a toast message on the UI thread.
     */
    private fun showToast(message: String) {
        runOnUiThread {
            Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        }
    }

    /**
     * Shows a native dialog to ensure the user sees the error even if Flutter fails.
     */
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

    private fun checkStatus(result: MethodChannel.Result) {
        try {
            val sdk = getSdk() ?: throw Exception("Payment SDK not initialized")
            val manager = sdk.transactionManager ?: throw Exception("Transaction Manager unavailable")
            
            if (manager.isSessionOpen) {
                showToast("Terminal Connected")
                result.success("CONNECTED")
            } else {
                showToast("Terminal Disconnected")
                result.success("DISCONNECTED")
            }
        } catch (e: Exception) {
            Log.e("Verifone", "Status Check Failed", e)
            showToast("Status Check Failed")
            result.error("STATUS_ERROR", e.localizedMessage, null)
        }
    }

    private fun runVerifoneTransaction(
        amount: Int, 
        currency: String, 
        flutterResult: MethodChannel.Result,
        resultSent: AtomicBoolean
    ) {
        try {
            val sdk = getSdk() ?: throw Exception("Verifone SDK could not be initialized. Please restart the app.")
            val manager = sdk.transactionManager ?: throw Exception("Terminal Communication Manager is unavailable.")
            
            val listener = object : CommerceListenerAdapter() {
                override fun handlePaymentCompletedEvent(event: PaymentCompletedEvent) {
                    try {
                        sdk.removeListener(this)
                        
                        if (resultSent.compareAndSet(false, true)) {
                            val status = event.status
                            if (status == StatusCode.SUCCESS) {
                                Log.i("Verifone", "Transaction Approved")
                                showToast("TRANSACTION APPROVED")
                                runOnUiThread {
                                    flutterResult.success("APPROVED")
                                }
                            } else {
                                val errorMsg = event.message ?: "Transaction Failed"
                                Log.w("Verifone", "Transaction failed: $errorMsg (Code: $status)")
                                showToast("DECLINED: $errorMsg")
                                runOnUiThread {
                                    flutterResult.error("DECLINED", errorMsg, status.toString())
                                }
                                showNativeErrorDialog("Transaction Declined", "$errorMsg (Code: $status)")
                            }
                        }
                    } catch (e: Exception) {
                        Log.e("Verifone", "Error handling payment completion", e)
                    }
                }

                override fun handleTransactionEvent(event: TransactionEvent) {
                    Log.d("Verifone", "Transaction Event: ${event.type}")
                }
                
                override fun handleStatus(status: Status) {
                    Log.d("Verifone", "SDK Status: ${status.message} (Code: ${status.status})")
                }
            }

            sdk.addListener(listener)

            // Setup Payment
            val payment = Payment.create()
            payment.transactionType = TransactionType.PAYMENT
            
            val amounts = AmountTotals.create(true)
            
            // Decimal handling for PSDK
            val decAmount = Decimal(amount.toDouble() / 100.0)
            amounts.total = decAmount
            
            payment.requestedAmounts = amounts
            payment.currency = currency
            
            Log.d("Verifone", "Initiating transaction: $amount $currency (Type: ${payment.transactionType})")
            
            if (!manager.isSessionOpen) {
                Log.d("Verifone", "Session not open, startPayment will attempt to connect.")
            }

            val startStatus = manager.startPayment(payment)
            
            if (startStatus.status != StatusCode.SUCCESS) {
                val failMsg = startStatus.message ?: "Could not start payment"
                Log.e("Verifone", "Failed to start payment: $failMsg (${startStatus.status})")
                showToast("Start Failed: $failMsg")
                if (resultSent.compareAndSet(false, true)) {
                    sdk.removeListener(listener)
                    flutterResult.error("START_FAILED", failMsg, startStatus.status.toString())
                }
                showNativeErrorDialog("Connection Error", "Terminal Error: $failMsg")
            }

        } catch (e: Exception) {
            Log.e("Verifone", "Fatal SDK Exception", e)
            if (resultSent.compareAndSet(false, true)) {
                flutterResult.error("FATAL_ERROR", e.localizedMessage, null)
            }
            showNativeErrorDialog("Verifone Error", e.localizedMessage ?: "A fatal error occurred.")
        }
    }
}
