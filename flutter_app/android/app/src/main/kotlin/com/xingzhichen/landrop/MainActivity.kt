package com.xingzhichen.landrop

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var secureFsChannel: MethodChannel? = null

    private external fun captureReceiveDirectoryIdentityNative(
        root: String,
        relativeParent: String,
    ): Array<String?>

    private external fun createReceiveEntryNative(
        root: String,
        relativeParent: String,
        leaf: String,
        expectedRootIdentity: String,
        expectedParentIdentity: String?,
    ): String

    private external fun publishReceiveEntryNative(
        root: String,
        relativeParent: String,
        leaf: String,
        destinationLeaf: String,
        expectedRootIdentity: String,
        expectedParentIdentity: String?,
        expectedLeafIdentity: String,
    ): Int

    private external fun captureReceiveEntryIdentityNative(
        root: String,
        relativeParent: String,
        leaf: String,
        expectedRootIdentity: String,
        expectedParentIdentity: String?,
        expectedLeafIdentity: String,
    ): String

    private external fun prepareReceiveQuarantineNative(
        root: String,
        relativeParent: String,
        leaf: String,
        quarantineSessionId: String,
        quarantineLeaf: String,
        expectedRootIdentity: String,
        expectedParentIdentity: String?,
        expectedLeafIdentity: String,
    ): String

    private external fun unlinkReceiveEntryNative(
        root: String,
        relativeParent: String,
        leaf: String,
        expectedRootIdentity: String,
        expectedParentIdentity: String?,
        expectedLeafIdentity: String,
        quarantineSessionId: String?,
        quarantineLeaf: String?,
        expectedQuarantineIdentity: String?,
    ): Int

    private external fun removeReceiveQuarantineNative(
        root: String,
        sessionId: String,
        expectedRootIdentity: String,
        expectedQuarantineIdentity: String,
    ): Int

    private external fun captureManagedFileDirectoryIdentityNative(root: String): String

    private external fun captureManagedFileLeafIdentityNative(
        root: String,
        leaf: String,
        expectedRootIdentity: String,
    ): String

    private external fun unlinkManagedFileNative(
        root: String,
        leaf: String,
        expectedRootIdentity: String,
        expectedLeafIdentity: String,
    ): Int

    private external fun readManagedFileChunkNative(
        root: String,
        leaf: String,
        expectedRootIdentity: String,
        expectedLeafIdentity: String,
        offset: Long,
        maxBytes: Int,
        metadata: LongArray,
    ): ByteArray

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "landrop/secure_fs")
        channel.setMethodCallHandler { call, result ->
            val method = call.method
            val isReceiveMethod = method == "captureReceiveDirectoryIdentity" ||
                method == "createReceiveEntry" ||
                method == "publishReceiveEntry" ||
                method == "captureReceiveEntryIdentity" ||
                method == "prepareReceiveQuarantine" ||
                method == "unlinkReceiveEntry" ||
                method == "removeReceiveQuarantine"
            val isManagedMethod = method == "captureManagedFileDirectoryIdentity" ||
                method == "captureManagedFileLeafIdentity" ||
                method == "unlinkManagedFile" ||
                method == "readManagedFileChunk"
            if (!isReceiveMethod && !isManagedMethod) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val arguments = call.arguments as? Map<*, *>
            if (arguments == null) {
                result.error(
                    "invalid_arguments",
                    "Expected root and relativeParent strings.",
                    null,
                )
                return@setMethodCallHandler
            }
            val root = arguments["root"] as? String
            if (root == null) {
                result.error(
                    "invalid_arguments",
                    if (isReceiveMethod) {
                        "Expected root and relativeParent strings."
                    } else {
                        "Expected a root string."
                    },
                    null,
                )
                return@setMethodCallHandler
            }

            if (method == "readManagedFileChunk") {
                val leaf = arguments["leaf"] as? String
                val expectedRootIdentity = arguments["expectedRootIdentity"] as? String
                val expectedLeafIdentity = arguments["expectedLeafIdentity"] as? String
                val offset = when (val value = arguments["offset"]) {
                    is Int -> value.toLong()
                    is Long -> value
                    else -> null
                }
                val maxBytes = when (val value = arguments["maxBytes"]) {
                    is Int -> value
                    is Long -> if (value in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) {
                        value.toInt()
                    } else {
                        null
                    }
                    else -> null
                }
                if (leaf == null || expectedRootIdentity == null ||
                    expectedLeafIdentity == null || offset == null || maxBytes == null ||
                    offset < 0 || maxBytes !in 1..(1024 * 1024)) {
                    result.error(
                        "invalid_arguments",
                        "Expected leaf and identity strings, a nonnegative offset, and maxBytes in 1..1048576.",
                        null,
                    )
                    return@setMethodCallHandler
                }
                secureFsExecutor.execute {
                    try {
                        val metadata = LongArray(2)
                        val bytes = readManagedFileChunkNative(
                            root,
                            leaf,
                            expectedRootIdentity,
                            expectedLeafIdentity,
                            offset,
                            maxBytes,
                            metadata,
                        )
                        mainHandler.post {
                            result.success(
                                mapOf(
                                    "bytes" to bytes,
                                    "fileLength" to metadata[0],
                                    "modifiedTimeMicros" to metadata[1],
                                ),
                            )
                        }
                    } catch (error: Throwable) {
                        mainHandler.post {
                            result.error(
                                "secure_fs_error",
                                error.message ?: "Could not securely read the managed file chunk.",
                                error.javaClass.name,
                            )
                        }
                    }
                }
                return@setMethodCallHandler
            }

            if (method == "captureManagedFileDirectoryIdentity") {
                secureFsExecutor.execute {
                    try {
                        val rootIdentity = captureManagedFileDirectoryIdentityNative(root)
                        mainHandler.post {
                            result.success(mapOf("rootIdentity" to rootIdentity))
                        }
                    } catch (error: Throwable) {
                        mainHandler.post {
                            result.error(
                                "secure_fs_error",
                                error.message ?: "Could not capture managed-file directory identity.",
                                error.javaClass.name,
                            )
                        }
                    }
                }
                return@setMethodCallHandler
            }

            if (method == "captureManagedFileLeafIdentity") {
                val leaf = arguments["leaf"] as? String
                val expectedRootIdentity = arguments["expectedRootIdentity"] as? String
                if (leaf == null || expectedRootIdentity == null) {
                    result.error(
                        "invalid_arguments",
                        "Expected leaf and expectedRootIdentity strings.",
                        null,
                    )
                    return@setMethodCallHandler
                }
                secureFsExecutor.execute {
                    try {
                        val leafIdentity = captureManagedFileLeafIdentityNative(
                            root,
                            leaf,
                            expectedRootIdentity,
                        )
                        mainHandler.post {
                            result.success(mapOf("leafIdentity" to leafIdentity))
                        }
                    } catch (error: Throwable) {
                        mainHandler.post {
                            result.error(
                                "secure_fs_error",
                                error.message ?: "Could not capture managed-file identity.",
                                error.javaClass.name,
                            )
                        }
                    }
                }
                return@setMethodCallHandler
            }

            if (method == "unlinkManagedFile") {
                val leaf = arguments["leaf"] as? String
                val expectedRootIdentity = arguments["expectedRootIdentity"] as? String
                val expectedLeafIdentity = arguments["expectedLeafIdentity"] as? String
                if (leaf == null || expectedRootIdentity == null || expectedLeafIdentity == null) {
                    result.error(
                        "invalid_arguments",
                        "Expected leaf, expectedRootIdentity, and expectedLeafIdentity strings.",
                        null,
                    )
                    return@setMethodCallHandler
                }
                secureFsExecutor.execute {
                    try {
                        val errorNumber = unlinkManagedFileNative(
                            root,
                            leaf,
                            expectedRootIdentity,
                            expectedLeafIdentity,
                        )
                        if (errorNumber != 0) {
                            throw IOException("Secure managed-file unlink failed (errno $errorNumber).")
                        }
                        mainHandler.post { result.success(null) }
                    } catch (error: Throwable) {
                        mainHandler.post {
                            result.error(
                                "secure_fs_error",
                                error.message ?: "Could not securely remove the managed file.",
                                error.javaClass.name,
                            )
                        }
                    }
                }
                return@setMethodCallHandler
            }

            if (method == "removeReceiveQuarantine") {
                val sessionId = arguments["sessionId"] as? String
                val expectedRootIdentity = arguments["expectedRootIdentity"] as? String
                val expectedQuarantineIdentity = arguments["expectedQuarantineIdentity"] as? String
                if (sessionId == null || expectedRootIdentity == null ||
                    expectedQuarantineIdentity == null) {
                    result.error(
                        "invalid_arguments",
                        "Expected sessionId, expectedRootIdentity, and expectedQuarantineIdentity strings.",
                        null,
                    )
                    return@setMethodCallHandler
                }
                secureFsExecutor.execute {
                    try {
                        val errorNumber = removeReceiveQuarantineNative(
                            root,
                            sessionId,
                            expectedRootIdentity,
                            expectedQuarantineIdentity,
                        )
                        if (errorNumber != 0) {
                            throw IOException("Secure receive-quarantine removal failed (errno $errorNumber).")
                        }
                        mainHandler.post { result.success(null) }
                    } catch (error: Throwable) {
                        mainHandler.post {
                            result.error(
                                "secure_fs_error",
                                error.message ?: "Could not securely remove the receive quarantine.",
                                error.javaClass.name,
                            )
                        }
                    }
                }
                return@setMethodCallHandler
            }

            val relativeParent = arguments["relativeParent"] as? String
            if (relativeParent == null) {
                result.error(
                    "invalid_arguments",
                    "Expected root and relativeParent strings.",
                    null,
                )
                return@setMethodCallHandler
            }

            if (method == "captureReceiveDirectoryIdentity") {
                secureFsExecutor.execute {
                    try {
                        val identities = captureReceiveDirectoryIdentityNative(root, relativeParent)
                        if (identities.size != 2) {
                            throw IOException("Native identity capture returned malformed data.")
                        }
                        val rootIdentity = identities[0]
                            ?: throw IOException("Native identity capture omitted the root identity.")
                        val parentIdentity = identities[1]
                        if ((relativeParent.isEmpty() && parentIdentity != null) ||
                            (relativeParent.isNotEmpty() && parentIdentity == null)) {
                            throw IOException("Native identity capture returned an invalid parent identity.")
                        }
                        mainHandler.post {
                            result.success(
                                mapOf(
                                    "rootIdentity" to rootIdentity,
                                    "parentIdentity" to parentIdentity,
                                ),
                            )
                        }
                    } catch (error: Throwable) {
                        mainHandler.post {
                            result.error(
                                "secure_fs_error",
                                error.message ?: "Could not capture receive-directory identity.",
                                error.javaClass.name,
                            )
                        }
                    }
                }
                return@setMethodCallHandler
            }

            val leaf = arguments["leaf"] as? String
            val expectedRootIdentity = arguments["expectedRootIdentity"] as? String
            if (leaf == null || expectedRootIdentity == null ||
                !arguments.containsKey("expectedParentIdentity")) {
                result.error(
                    "invalid_arguments",
                    "Expected leaf and directory identity arguments.",
                    null,
                )
                return@setMethodCallHandler
            }
            val parentIdentityValue = arguments["expectedParentIdentity"]
            val expectedParentIdentity = when (parentIdentityValue) {
                null -> null
                is String -> parentIdentityValue
                else -> {
                    result.error(
                        "invalid_arguments",
                        "Invalid expectedParentIdentity.",
                        null,
                    )
                    return@setMethodCallHandler
                }
            }
            if ((relativeParent.isEmpty() && expectedParentIdentity != null) ||
                (relativeParent.isNotEmpty() && expectedParentIdentity == null)) {
                result.error(
                    "invalid_arguments",
                    "expectedParentIdentity must be null exactly when relativeParent is empty.",
                    null,
                )
                return@setMethodCallHandler
            }
            val needsExpectedLeafIdentity = method == "captureReceiveEntryIdentity" ||
                method == "publishReceiveEntry" ||
                method == "unlinkReceiveEntry" ||
                method == "prepareReceiveQuarantine"
            val expectedLeafIdentity = if (needsExpectedLeafIdentity) {
                arguments["expectedLeafIdentity"] as? String
            } else {
                null
            }
            if (needsExpectedLeafIdentity && expectedLeafIdentity == null) {
                result.error(
                    "invalid_arguments",
                    "Expected an expectedLeafIdentity string.",
                    null,
                )
                return@setMethodCallHandler
            }
            val destinationLeaf = if (method == "publishReceiveEntry") {
                arguments["destinationLeaf"] as? String
            } else {
                null
            }
            if (method == "publishReceiveEntry" && destinationLeaf == null) {
                result.error(
                    "invalid_arguments",
                    "Expected a destinationLeaf string.",
                    null,
                )
                return@setMethodCallHandler
            }
            val quarantineSessionId = if (method == "prepareReceiveQuarantine") {
                arguments["quarantineSessionId"] as? String
            } else if (method == "unlinkReceiveEntry") {
                when (val value = arguments["quarantineSessionId"]) {
                    null -> null
                    is String -> value
                    else -> {
                        result.error(
                            "invalid_arguments",
                            "Invalid quarantineSessionId.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                }
            } else {
                null
            }
            val quarantineLeaf = if (method == "prepareReceiveQuarantine" ||
                method == "unlinkReceiveEntry") {
                when (val value = arguments["quarantineLeaf"]) {
                    null -> null
                    is String -> value
                    else -> {
                        result.error(
                            "invalid_arguments",
                            "Invalid quarantineLeaf.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                }
            } else {
                null
            }
            if (method == "prepareReceiveQuarantine" &&
                (quarantineSessionId == null || quarantineLeaf == null)) {
                result.error(
                    "invalid_arguments",
                    "Expected quarantineSessionId and quarantineLeaf strings.",
                    null,
                )
                return@setMethodCallHandler
            }
            val expectedQuarantineIdentity = if (method == "unlinkReceiveEntry") {
                when (val value = arguments["expectedQuarantineIdentity"]) {
                    null -> null
                    is String -> value
                    else -> {
                        result.error(
                            "invalid_arguments",
                            "Invalid expectedQuarantineIdentity.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                }
            } else {
                null
            }
            if (method == "unlinkReceiveEntry" &&
                ((quarantineSessionId != null || quarantineLeaf != null ||
                    expectedQuarantineIdentity != null) &&
                    (quarantineSessionId == null || quarantineLeaf == null ||
                        expectedQuarantineIdentity == null))) {
                result.error(
                    "invalid_arguments",
                    "quarantineSessionId, quarantineLeaf, and expectedQuarantineIdentity must be provided together.",
                    null,
                )
                return@setMethodCallHandler
            }

            secureFsExecutor.execute {
                try {
                    when (method) {
                        "publishReceiveEntry" -> {
                            val errorNumber = publishReceiveEntryNative(
                                root,
                                relativeParent,
                                leaf,
                                destinationLeaf!!,
                                expectedRootIdentity,
                                expectedParentIdentity,
                                expectedLeafIdentity!!,
                            )
                            when (errorNumber) {
                                0 -> mainHandler.post { result.success(true) }
                                android.system.OsConstants.EEXIST ->
                                    mainHandler.post { result.success(false) }
                                else -> throw IOException(
                                    "Secure receive-entry move failed (errno $errorNumber).",
                                )
                            }
                        }
                        "createReceiveEntry" -> {
                            val leafIdentity = createReceiveEntryNative(
                                root,
                                relativeParent,
                                leaf,
                                expectedRootIdentity,
                                expectedParentIdentity,
                            )
                            mainHandler.post { result.success(mapOf("leafIdentity" to leafIdentity)) }
                        }
                        "captureReceiveEntryIdentity" -> {
                            val leafIdentity = captureReceiveEntryIdentityNative(
                                root,
                                relativeParent,
                                leaf,
                                expectedRootIdentity,
                                expectedParentIdentity,
                                expectedLeafIdentity!!,
                            )
                            mainHandler.post { result.success(mapOf("leafIdentity" to leafIdentity)) }
                        }
                        "prepareReceiveQuarantine" -> {
                            val quarantineIdentity = prepareReceiveQuarantineNative(
                                root,
                                relativeParent,
                                leaf,
                                quarantineSessionId!!,
                                quarantineLeaf!!,
                                expectedRootIdentity,
                                expectedParentIdentity,
                                expectedLeafIdentity!!,
                            )
                            mainHandler.post {
                                result.success(mapOf("quarantineIdentity" to quarantineIdentity))
                            }
                        }
                        else -> {
                            val errorNumber = unlinkReceiveEntryNative(
                                root,
                                relativeParent,
                                leaf,
                                expectedRootIdentity,
                                expectedParentIdentity,
                                expectedLeafIdentity!!,
                                quarantineSessionId,
                                quarantineLeaf,
                                expectedQuarantineIdentity,
                            )
                            if (errorNumber != 0) {
                                throw IOException("Secure unlink failed (errno $errorNumber).")
                            }
                            mainHandler.post { result.success(null) }
                        }
                    }
                } catch (error: Throwable) {
                    mainHandler.post {
                        result.error(
                            "secure_fs_error",
                            error.message ?: "Could not securely access the receive entry.",
                            error.javaClass.name,
                        )
                    }
                }
            }
        }
        secureFsChannel = channel
    }

    companion object {
        init {
            System.loadLibrary("landrop_secure_fs")
        }

        private val secureFsExecutor = Executors.newSingleThreadExecutor { task ->
            Thread(task, "landrop-secure-fs").apply { isDaemon = true }
        }
    }
}
