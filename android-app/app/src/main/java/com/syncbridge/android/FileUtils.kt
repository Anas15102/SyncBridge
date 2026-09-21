package com.syncbridge.android

import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import java.io.File

object FileUtils {

    fun getFileName(context: Context, uri: Uri): String {
        var result: String? = null
        if (uri.scheme == "content") {
            try {
                context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (nameIndex >= 0) {
                            result = cursor.getString(nameIndex)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w("FileUtils", "Error resolving display name from query: $e")
            }
        }
        if (result.isNullOrBlank()) {
            val path = uri.path
            val cut = path?.lastIndexOf('/') ?: -1
            if (cut != -1 && path != null) {
                result = path.substring(cut + 1)
            }
        }
        if (result.isNullOrBlank() || result?.contains(":") == true) {
            val mime = context.contentResolver.getType(uri)
            val ext = if (mime != null) {
                MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "dat"
            } else "dat"
            result = "file_${System.currentTimeMillis()}.$ext"
        }
        return result ?: "file_${System.currentTimeMillis()}.dat"
    }

    fun getFileSize(context: Context, uri: Uri): Long {
        if (uri.scheme == "content") {
            try {
                context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (sizeIndex >= 0) {
                            return cursor.getLong(sizeIndex)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w("FileUtils", "Error resolving size: $e")
            }
        }
        return 0L
    }

    fun uniqueFile(directory: File, filename: String): File {
        var target = File(directory, filename)
        var counter = 1
        val dot = filename.lastIndexOf('.')
        val name = if (dot != -1) filename.substring(0, dot) else filename
        val ext = if (dot != -1) filename.substring(dot) else ""
        while (target.exists()) {
            target = File(directory, "$name ($counter)$ext")
            counter++
        }
        return target
    }

    fun openDownloadOutputStream(context: Context, filename: String): Pair<java.io.OutputStream, String> {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val contentValues = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, filename)
                put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            }
            val uri = resolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
            if (uri != null) {
                val stream = resolver.openOutputStream(uri)
                if (stream != null) {
                    return Pair(stream, filename)
                }
            }
        }
        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            ?: context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: context.filesDir
        if (!downloads.exists()) downloads.mkdirs()
        val dest = uniqueFile(downloads, filename)
        return Pair(java.io.FileOutputStream(dest), dest.name)
    }
}
