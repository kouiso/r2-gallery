package app.r2gallery.r2_gallery;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Android frameworkを代用した成功扱いにはせず、production gateの呼出順序だけを検査する。 */
public final class ForegroundPromotionProbe {
    private static void equal(List<String> actual, String... expected) {
        if (!actual.equals(Arrays.asList(expected))) throw new AssertionError(actual);
    }
    public static void main(String[] args) {
        List<String> events = new ArrayList<>();
        ForegroundPromotion gate = new ForegroundPromotion();
        gate.stop(() -> events.add("stop"));
        equal(events);
        gate.promote(() -> events.add("foreground"));
        equal(events, "foreground", "stop");
        System.out.println("PASS stop-before-create");

        events.clear();
        ForegroundPromotion normal = new ForegroundPromotion();
        normal.promote(() -> events.add("foreground"));
        normal.stop(() -> events.add("stop"));
        equal(events, "foreground", "stop");
        System.out.println("PASS normal-start-stop");

        events.clear();
        ForegroundPromotion reentrant = new ForegroundPromotion();
        reentrant.promote(() -> {
            events.add("foreground-begin");
            reentrant.stop(() -> events.add("stop"));
            events.add("foreground-complete");
        });
        equal(events, "foreground-begin", "foreground-complete", "stop");
        System.out.println("PASS stop-during-promotion");

        normal.promote(() -> { throw new AssertionError("duplicate promotion"); });
        System.out.println("PASS no-duplicate-promotion");

        ForegroundPromotion denied = new ForegroundPromotion();
        events.clear();
        denied.stop(() -> events.add("stop"));
        try {
            denied.promote(() -> { throw new SecurityException("synthetic"); });
            throw new AssertionError("promotion failure swallowed");
        } catch (SecurityException expected) { equal(events); }
        System.out.println("PASS promotion-failure-is-not-success");
    }
}
