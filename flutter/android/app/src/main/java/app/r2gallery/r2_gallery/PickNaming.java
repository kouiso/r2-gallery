package app.r2gallery.r2_gallery;

import java.util.Locale;

/**
 * 選んだ URI の見せる名前の整え方。GET_CONTENT が返す URI は表示名を持たないことがあり、
 * 拡張子の無い名前のままだと一覧に出ず種類も拾えないので、MIME から拡張子を借りて足す。
 */
public final class PickNaming {
    private PickNaming() {}

    /** MIME（contentResolver.getType）から借りる拡張子。一覧に出る系統だけを返す。 */
    public static String extForMime(String mime) {
        if (mime == null) return null;
        switch (mime.toLowerCase(Locale.ROOT).split(";")[0].trim()) {
            case "image/jpeg": return ".jpg";
            case "image/png": return ".png";
            case "image/webp": return ".webp";
            case "image/gif": return ".gif";
            case "image/avif": return ".avif";
            case "image/heic": return ".heic";
            case "image/heif": return ".heif";
            case "image/bmp": return ".bmp";
            case "video/mp4": return ".mp4";
            case "video/webm": return ".webm";
            case "video/quicktime": return ".mov";
            case "video/x-m4v": return ".m4v";
            case "video/x-matroska": return ".mkv";
            case "video/mp2t": return ".ts";
            case "video/mpeg": return ".mpg";
            case "video/x-msvideo": return ".avi";
            case "video/x-flv": return ".flv";
            case "video/3gpp": return ".3gp";
            case "video/x-ms-wmv": return ".wmv";
            default: return null;
        }
    }

    /**
     * 点を含まない名前にだけ拡張子を足す。拡張子らしき物を持つ名前はそのまま通す
     * （借りた拡張子で勝手に付け替えると、選んだ側の名が変わって見えるため）。
     * 名が無い時は "media" を名乗る。
     */
    public static String resolve(String name, String mime) {
        String base = (name == null || name.trim().isEmpty()) ? "media" : name.trim();
        if (base.contains(".")) return base;
        String ext = extForMime(mime);
        return ext == null ? base : base + ext;
    }
}
