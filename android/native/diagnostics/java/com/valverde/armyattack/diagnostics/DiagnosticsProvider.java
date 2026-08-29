package com.valverde.armyattack.diagnostics;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileNotFoundException;

public final class DiagnosticsProvider extends ContentProvider {
    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public String getType(Uri uri) {
        return "application/zip";
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode) && !"rt".equals(mode)) {
            throw new FileNotFoundException("read_only");
        }
        File file = resolve(uri);
        if (!file.exists() || !file.isFile()) {
            throw new FileNotFoundException(file.getAbsolutePath());
        }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        File file = resolve(uri);
        String[] columns = projection;
        if (columns == null || columns.length == 0) {
            columns = new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE};
        }
        MatrixCursor cursor = new MatrixCursor(columns, 1);
        MatrixCursor.RowBuilder row = cursor.newRow();
        for (String column : columns) {
            if (OpenableColumns.DISPLAY_NAME.equals(column)) {
                row.add(file.getName());
            } else if (OpenableColumns.SIZE.equals(column)) {
                row.add(file.exists() ? file.length() : 0L);
            } else {
                row.add(null);
            }
        }
        return cursor;
    }

    private File resolve(Uri uri) {
        if (getContext() == null) {
            return new File("");
        }
        String encoded = uri == null ? null : uri.getLastPathSegment();
        String name = encoded == null ? "" : Uri.decode(encoded);
        if (!name.matches("[A-Za-z0-9._-]+\\.zip")) {
            return new File(getContext().getCacheDir(), "invalid");
        }
        File dir = new File(getContext().getCacheDir(), "armyattack-diagnostics");
        return new File(dir, name);
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) { return 0; }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) { return 0; }

    @Override
    public Uri insert(Uri uri, ContentValues values) { return null; }
}
