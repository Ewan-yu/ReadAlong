package com.ewanyu.reader_app

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterShellArgs
import java.io.File

class MainActivity : FlutterActivity() {
    override fun getFlutterShellArgs(): FlutterShellArgs {
        val shellArgs = super.getFlutterShellArgs()
        if (File("/dev/bstpgaipc").exists()) {
            // BlueStacks' GPU shared-memory bridge can crash Flutter's raster
            // thread while a large picture-book surface is being updated.
            // Keep hardware rendering on real Android devices and use Skia's
            // software backend only when that BlueStacks device is present.
            shellArgs.add(FlutterShellArgs.ARG_ENABLE_SOFTWARE_RENDERING)
            Log.i("ReadAlong", "BlueStacks detected; software rendering enabled")
        }
        return shellArgs
    }
}
