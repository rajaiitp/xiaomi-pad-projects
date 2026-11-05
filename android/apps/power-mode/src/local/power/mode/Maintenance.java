package local.power.mode;

import android.content.Context;

import java.io.File;

final class Maintenance {
    private Maintenance() {}

    static boolean active(Context context) {
        return new File(context.createDeviceProtectedStorageContext().getFilesDir(), "maintenance")
                .exists();
    }
}
