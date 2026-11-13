package app.r2gallery.r2_gallery;

import java.util.Arrays;

/** Android framework を使わず、小窓の判定の境界だけを検査する（javac + java で実行できる）。 */
public final class PipPolicyProbe {
    private static int checks = 0;

    private static void ratio(String name, int w, int h, int num, int den) {
        checks++;
        int[] got = PipPolicy.aspect(w, h);
        if (got[0] != num || got[1] != den) {
            throw new AssertionError(name + ": " + Arrays.toString(got) + " != " + num + "/" + den);
        }
    }

    private static void is(String name, Object got, Object want) {
        checks++;
        if (!got.equals(want)) throw new AssertionError(name + ": " + got + " != " + want);
    }

    public static void main(String[] args) {
        ratio("16:9", 1920, 1080, 16, 9);
        ratio("下限ちょうど", 100, 239, 100, 239);
        ratio("下限ちょうど(倍)", 200, 478, 100, 239);
        // 0.42 は 100/239(=0.41841...) より大きい。下限を 0.42 に戻すと、この細い動画が弾かれて落ちる
        ratio("下限より細い", 41, 100, 100, 239);
        // 100/239 は 0.4184…。0.419 は OS が受け付ける範囲内なので、そのまま通る
        ratio("下限のすぐ内側", 419, 1000, 419, 1000);
        ratio("上限ちょうど", 239, 100, 239, 100);
        ratio("上限より広い", 240, 100, 239, 100);
        ratio("0 の幅", 0, 100, 16, 9);
        ratio("0 の高さ", 100, 0, 16, 9);
        ratio("負の幅", -4, 9, 16, 9);
        ratio("正方形", 640, 640, 1, 1);
        ratio("長辺が大きい", 2_000_000_000, 1_000_000_000, 2, 1);
        ratio("長辺が大きく広すぎる", 2_000_000_000, 100, 239, 100);

        is("API 25 は入らない", PipPolicy.route(25, true), PipPolicy.Route.NONE);
        is("API 26", PipPolicy.route(26, true), PipPolicy.Route.USER_LEAVE_HINT);
        is("API 30", PipPolicy.route(30, true), PipPolicy.Route.USER_LEAVE_HINT);
        is("API 31", PipPolicy.route(31, true), PipPolicy.Route.SYSTEM_AUTO_ENTER);
        is("API 36", PipPolicy.route(36, true), PipPolicy.Route.SYSTEM_AUTO_ENTER);
        is("非対応端末", PipPolicy.route(36, false), PipPolicy.Route.NONE);

        is("再生中で armed", PipPolicy.autoEnterAllowed(true, true, false), true);
        is("armed でも一時停止", PipPolicy.autoEnterAllowed(true, false, false), false);
        is("armed でも終了後", PipPolicy.autoEnterAllowed(true, true, true), false);
        is("armed でない", PipPolicy.autoEnterAllowed(false, true, false), false);

        is("画面が見えている = 元に戻す", PipPolicy.restoring(true), true);
        is("画面が見えない = ×", PipPolicy.restoring(false), false);
        System.out.println("PipPolicyProbe ok: " + checks + " checks");
    }
}
