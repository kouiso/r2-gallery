package app.r2gallery.r2_gallery;

/**
 * 写真・動画を選ぶ Intent の仕様。javac だけで検査できるよう、action・型・複数可否・
 * 仲介の範囲を Android 依存なしの値で返す。UploadPicker.kt はここだけを見て Intent を組み立てる。
 */
public final class PickSpec {
    private PickSpec() {}

    /** ピッカーの action（android.content.Intent の同名定数と同じ文字列）。 */
    public static String action() {
        return "android.intent.action.OPEN_DOCUMENT";
    }

    /** 選ばせる MIME。一覧に出るのは画像・動画だけなのでこの2系統に限る。 */
    public static String[] mimeTypes() {
        return new String[] {"image/*", "video/*"};
    }

    /** まとめて選ぶか。 */
    public static boolean allowMultiple() {
        return true;
    }

    /** Intent.CATEGORY_OPENABLE の文字列。開ける stream を持つ仲介に限る。 */
    public static String openableCategory() {
        return "android.intent.category.OPENABLE";
    }
}
