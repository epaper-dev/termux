package com.termux.shared.termux.extrakeys;

import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.view.ContextThemeWrapper;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import com.google.android.material.button.MaterialButton;
import com.termux.shared.R;

import org.junit.Test;
import org.junit.runner.RunWith;

import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public class ExtraKeysAppearanceTest {
    @Test
    public void transparentKeysSurviveRecreationAndColorChanges() throws Exception {
        ExtraKeysInfo info = new ExtraKeysInfo("[[\"ESC\",\"CTRL\"]]", "default",
            ExtraKeysConstants.CONTROL_CHARS_ALIASES);
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            // Fresh views model cold starts; reloads model terminal colour changes.
            for (int start = 0; start < 2; start++) {
                ExtraKeysView view = new ExtraKeysView(new ContextThemeWrapper(
                    InstrumentationRegistry.getInstrumentation().getTargetContext(),
                    R.style.Theme_BaseActivity_Light_NoActionBar), null);
                view.setButtonColors(Color.BLACK, Color.RED, Color.TRANSPARENT, Color.GRAY);
                for (int text : new int[]{Color.BLACK, Color.WHITE, Color.BLACK}) {
                    view.setButtonTextColor(text);
                    view.reload(info, 50);
                    MaterialButton key = (MaterialButton) view.getChildAt(0);
                    assertTrue(key.getBackground() instanceof ColorDrawable);
                    assertEquals(Color.TRANSPARENT, ((ColorDrawable) key.getBackground()).getColor());
                    assertEquals(text, key.getCurrentTextColor());
                    // Press/release uses setBackgroundColor on the replacement drawable.
                    key.setBackgroundColor(Color.GRAY);
                    key.setBackgroundColor(Color.TRANSPARENT);
                    assertEquals(Color.TRANSPARENT, ((ColorDrawable) key.getBackground()).getColor());
                }
                view.mSpecialButtons.get(SpecialButton.CTRL).setIsActive(true);
                view.reload(info, 50);
                assertEquals(Color.RED, ((MaterialButton) view.getChildAt(1)).getCurrentTextColor());
            }
        });
    }
}
