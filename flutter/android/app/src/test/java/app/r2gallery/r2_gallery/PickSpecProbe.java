package app.r2gallery.r2_gallery;

import java.util.Arrays;

/**
 * ピッカーの Intent の仕様を検査する。OPEN_DOCUMENT は DocumentsProvider しか
 * 選び先に出さず Google フォトが出ない（#219 の退行）ため、action は GET_CONTENT を要求する。
 */
public final class PickSpecProbe {
    private static void is(String name, Object got, Object want) {
        if (!got.equals(want)) throw new AssertionError(name + ": " + got + " != " + want);
    }

    public static void main(String[] args) {
        // Google フォト等の DocumentsProvider 以外の選び先が要るので GET_CONTENT。
        // OPEN_DOCUMENT にすると Files（DocumentsUI）だけになり #219 の退行になる
        is("action", PickSpec.action(), "android.intent.action.GET_CONTENT");
        is("mimeTypes", Arrays.asList(PickSpec.mimeTypes()),
                Arrays.asList("image/*", "video/*"));
        is("allowMultiple", PickSpec.allowMultiple(), true);
        is("openableCategory", PickSpec.openableCategory(),
                "android.intent.category.OPENABLE");
        System.out.println("PickSpecProbe ok");
    }
}
