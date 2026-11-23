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

        // 表示名を持たない URI には MIME から拡張子を借りる（無いと一覧に出ない）
        is("segment+jpeg", PickNaming.resolve("abc123", "image/jpeg"), "abc123.jpg");
        is("segment+mp4", PickNaming.resolve("abc123", "video/mp4"), "abc123.mp4");
        is("segment+heic", PickNaming.resolve("p", "image/heic"), "p.heic");
        is("segment+quicktime", PickNaming.resolve("p", "video/quicktime"), "p.mov");
        is("mime with params", PickNaming.resolve("p", "image/jpeg; charset=x"), "p.jpg");
        is("null name+jpeg", PickNaming.resolve(null, "image/jpeg"), "media.jpg");
        is("null name+unknown mime", PickNaming.resolve(null, "application/octet-stream"),
                "media");
        is("named file kept", PickNaming.resolve("IMG_1.jpg", "image/jpeg"), "IMG_1.jpg");
        is("dot name kept", PickNaming.resolve("x.txt", "image/jpeg"), "x.txt");
        is("blank name", PickNaming.resolve("  ", "image/png"), "media.png");
        System.out.println("PickSpecProbe ok");
    }
}
