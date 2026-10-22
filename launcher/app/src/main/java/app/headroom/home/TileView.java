package app.headroom.home;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.drawable.Drawable;
import android.text.TextPaint;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.View;

/** One dock or grid tile: icon above, label below, a highlight when pressed or focused. */
public final class TileView extends View {

    private static final float LABEL_SP = 18f;
    private static final float LABEL_MIN_SP = 12f;

    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final TextPaint labelPaint = new TextPaint(Paint.ANTI_ALIAS_FLAG);
    private final Rect iconRect = new Rect();
    private final RectF highlightRect = new RectF();
    private final float radius;
    private final float padding;
    private final float labelSize;
    private final float labelMinSize;
    private final int highlightColor;

    private Bitmap icon;
    private Drawable iconDrawable;
    private String label = "";

    public TileView(Context context) {
        super(context);
        float density = getResources().getDisplayMetrics().density;
        radius = 12 * density;
        padding = 8 * density;
        int accent = getResources().getColor(
            R.color.accent,
            context.getTheme()
        );
        highlightColor = Color.argb(
            70,
            Color.red(accent),
            Color.green(accent),
            Color.blue(accent)
        );
        labelPaint.setColor(
            getResources().getColor(R.color.text, context.getTheme())
        );
        labelPaint.setTextAlign(Paint.Align.CENTER);
        labelSize = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_SP,
            LABEL_SP,
            getResources().getDisplayMetrics()
        );
        labelMinSize = TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_SP,
            LABEL_MIN_SP,
            getResources().getDisplayMetrics()
        );
        labelPaint.setTextSize(labelSize);
        int minimum = Math.round(GridMath.MIN_TOUCH_DP * density);
        setMinimumWidth(minimum);
        setMinimumHeight(minimum);
        setFocusable(true);
        setClickable(true);
        setLongClickable(true);
    }

    public void bind(Bitmap icon, String label) {
        this.icon = icon;
        this.iconDrawable = null;
        setLabel(label);
    }

    public void bindRes(int drawableRes, String label) {
        this.icon = null;
        this.iconDrawable = getContext().getDrawable(drawableRes);
        setLabel(label);
    }

    private void setLabel(String label) {
        this.label = label == null ? "" : label;
        setContentDescription(this.label);
        invalidate();
    }

    @Override
    protected void onMeasure(int widthSpec, int heightSpec) {
        int width = MeasureSpec.getSize(widthSpec);
        int height = MeasureSpec.getSize(heightSpec);
        int widthMode = MeasureSpec.getMode(widthSpec);
        int heightMode = MeasureSpec.getMode(heightSpec);
        int minWidth = getSuggestedMinimumWidth();
        int minHeight = getSuggestedMinimumHeight();

        if (widthMode == MeasureSpec.UNSPECIFIED) width = minWidth;
        if (heightMode == MeasureSpec.UNSPECIFIED) height = Math.max(
            width,
            minHeight
        );
        width = Math.max(width, minWidth);
        height = Math.max(height, minHeight);
        if (heightMode == MeasureSpec.AT_MOST) height = Math.min(height, width);
        setMeasuredDimension(
            resolveSize(width, widthSpec),
            resolveSize(height, heightSpec)
        );
    }

    @Override
    protected void onDraw(Canvas canvas) {
        int width = getWidth();
        int height = getHeight();
        if (isPressed() || isFocused()) {
            fill.setColor(highlightColor);
            highlightRect.set(
                padding / 2,
                padding / 2,
                width - padding / 2,
                height - padding / 2
            );
            canvas.drawRoundRect(highlightRect, radius, radius, fill);
        }

        int iconArea = (int) (height * 0.70f);
        int iconSize = Math.min((int) (width * 0.60f), iconArea);
        int left = (width - iconSize) / 2;
        int top = (iconArea - iconSize) / 2;
        iconRect.set(left, top, left + iconSize, top + iconSize);
        if (icon != null) {
            canvas.drawBitmap(icon, null, iconRect, null);
        } else if (iconDrawable != null) {
            iconDrawable.setBounds(iconRect);
            iconDrawable.draw(canvas);
        }

        if (!label.isEmpty()) {
            float available = Math.max(0, width - 2 * padding);
            labelPaint.setTextSize(labelSize);
            float measured = labelPaint.measureText(label);
            if (measured > available) {
                labelPaint.setTextSize(
                    Math.max(labelMinSize, (labelSize * available) / measured)
                );
            }
            CharSequence shown = TextUtils.ellipsize(
                label,
                labelPaint,
                available,
                TextUtils.TruncateAt.END
            );
            float baseline =
                iconArea +
                (height - iconArea) / 2f -
                (labelPaint.ascent() + labelPaint.descent()) / 2f;
            canvas.drawText(shown.toString(), width / 2f, baseline, labelPaint);
        }
    }

    @Override
    protected void drawableStateChanged() {
        super.drawableStateChanged();
        invalidate();
    }
}
