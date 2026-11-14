package app.r2gallery.r2_gallery;

/**
 * 小窓まわりの判定。android.* に触れない純粋な関数だけを置き、JVM 単体の検査で境界を固定する。
 * Rational や Activity を持ち込むと、検査側で未実装のスタブに当たって落ちるため。
 */
public final class PipPolicy {
    private PipPolicy() {}

    /** OS が受け付ける縦横比の範囲は 100/239〜239/100。 */
    static final int LIMIT_SMALL = 100;
    static final int LIMIT_LARGE = 239;

    /** 小窓へ入る道。API 31 以上は OS が自動で入り、26〜30 は onUserLeaveHint で自分から入る。 */
    public enum Route { NONE, SYSTEM_AUTO_ENTER, USER_LEAVE_HINT }

    /**
     * 整数の幅・高さから {分子, 分母} を決める。
     * 比を小数にして丸めると境界ちょうどの値が OS の範囲を外れるので、整数のまま比べる。
     * 0 以下や取れない値は 16:9 に落とす。
     */
    public static int[] aspect(int width, int height) {
        if (width <= 0 || height <= 0) return new int[] {16, 9};
        // 長辺が大きいと掛け算が int を超えるため long で比べる
        long w = width;
        long h = height;
        if (w * LIMIT_LARGE < h * LIMIT_SMALL) return new int[] {LIMIT_SMALL, LIMIT_LARGE};
        if (w * LIMIT_SMALL > h * LIMIT_LARGE) return new int[] {LIMIT_LARGE, LIMIT_SMALL};
        int g = gcd(width, height);
        return new int[] {width / g, height / g};
    }

    private static int gcd(int a, int b) {
        while (b != 0) {
            int t = a % b;
            a = b;
            b = t;
        }
        return a;
    }

    /**
     * 自動で入ってよいか。Dart が「入ってよい」と知らせ（armed）、native も再生中と見ている時だけ。
     * 一時停止の知らせが Dart から遅れても、native の再生状態で止める。
     */
    public static boolean autoEnterAllowed(boolean armed, boolean playing, boolean ended) {
        return armed && playing && !ended;
    }

    public static Route route(int sdk, boolean supported) {
        if (!supported || sdk < 26) return Route.NONE;
        return sdk >= 31 ? Route.SYSTEM_AUTO_ENTER : Route.USER_LEAVE_HINT;
    }

    /**
     * 小窓が閉じた理由。画面が STARTED 以上なら「元に戻す」、そうでなければ × で閉じた。
     * 時間差で見分けると端末の速さに左右されるので、閉じた時点の画面の状態で決める。
     */
    public static boolean restoring(boolean activityStarted) {
        return activityStarted;
    }

    /**
     * 小窓を閉じる依頼（exitPip）を受けてよい session か。
     * 再生が小窓の中で自然に終わると clear で snapshot は null になり、小窓の session だけが残る。
     * その後のロック・接続変更でも小窓ごと閉じられるよう、現在の session と小窓の session の両方を通す。
     */
    public static boolean acceptsExit(String session, String snapshotSession, String pipSession) {
        if (session == null) return false;
        return session.equals(snapshotSession) || session.equals(pipSession);
    }

    /** 小窓のボタンが送る放送の名前。アプリ内の受信側だけがこの 2 つを受ける。 */
    public static final String ACTION_PLAY = "app.r2gallery.pip.PLAY";
    public static final String ACTION_PAUSE = "app.r2gallery.pip.PAUSE";

    /**
     * 小窓に出すボタンが押された時に Dart へ送る命令。再生中なら一時停止、それ以外は再生。
     * 見た目と命令を同じ判定から決めるので、ボタンの絵と押した結果がずれない。
     */
    public static String nextCommand(boolean playing) {
        return playing ? "pause" : "play";
    }

    /** ボタンに結びつける放送の名前。[nextCommand] と対になる。 */
    public static String actionName(boolean playing) {
        return playing ? ACTION_PAUSE : ACTION_PLAY;
    }

    /**
     * 受けた放送の名前から Dart への命令を決める。知らない名前は null（無視する）。
     * 再生か一時停止の 2 つ以外は通さず、他アプリの放送が命令にならないようにする。
     */
    public static String commandFor(String intentAction) {
        if (ACTION_PLAY.equals(intentAction)) return "play";
        if (ACTION_PAUSE.equals(intentAction)) return "pause";
        return null;
    }
}
