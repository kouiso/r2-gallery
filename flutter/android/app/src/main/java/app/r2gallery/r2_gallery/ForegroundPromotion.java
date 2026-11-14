package app.r2gallery.r2_gallery;

import java.util.ArrayDeque;

/** 起動直後の停止も、OSへ前面化を届けてから実行する。同じmain threadで使う。 */
public final class ForegroundPromotion {
    private boolean promoted;
    private final ArrayDeque<Runnable> pendingStops = new ArrayDeque<>();

    public void promote(Runnable action) {
        if (promoted) return;
        action.run();
        promoted = true;
        while (!pendingStops.isEmpty()) pendingStops.removeFirst().run();
    }

    public void stop(Runnable action) {
        if (promoted) action.run();
        else pendingStops.addLast(action);
    }
}
