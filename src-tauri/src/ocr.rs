use image::{DynamicImage, GenericImageView, ImageFormat, imageops::FilterType};
use std::io::Cursor;
use tesseract::Tesseract;

/// Run OCR on the given image and return the recognised text.
///
/// We do two preprocessing tricks before handing it to Tesseract because OCR
/// on screen captures is consistently better with them:
///
/// 1. Upscale small selections — Tesseract is trained on roughly 300 DPI input
///    and screen text is much smaller. Scaling up to ~3x for tiny regions
///    dramatically improves accuracy on small UI text.
/// 2. Convert to grayscale — reduces noise from antialiasing and subpixel
///    rendering on LCD displays.
pub fn extract_text(image: &DynamicImage) -> Result<String, String> {
    let processed = preprocess(image);

    // Encode to PNG for Tesseract
    let mut buf = Cursor::new(Vec::new());
    processed
        .write_to(&mut buf, ImageFormat::Png)
        .map_err(|e| format!("encode png: {e}"))?;
    let bytes = buf.into_inner();

    let text = Tesseract::new(None, Some("eng"))
        .map_err(|e| format!("tesseract init (is libtesseract installed?): {e}"))?
        .set_image_from_mem(&bytes)
        .map_err(|e| format!("set image: {e}"))?
        .get_text()
        .map_err(|e| format!("recognize: {e}"))?;

    // Tesseract often returns trailing whitespace and stray form-feeds
    Ok(text.trim().replace('\u{000C}', "").to_string())
}

fn preprocess(image: &DynamicImage) -> DynamicImage {
    let (w, h) = image.dimensions();

    // Target a minimum height of ~600 px for the smaller dimension to give
    // Tesseract something resembling print-quality input.
    let min_dim = w.min(h);
    let scale = if min_dim < 200 {
        3.0
    } else if min_dim < 400 {
        2.0
    } else {
        1.0
    };

    let scaled = if (scale - 1.0_f32).abs() > f32::EPSILON {
        let new_w = (w as f32 * scale) as u32;
        let new_h = (h as f32 * scale) as u32;
        image.resize(new_w, new_h, FilterType::Lanczos3)
    } else {
        image.clone()
    };

    // Grayscale tends to produce cleaner OCR than full-color RGB
    DynamicImage::ImageLuma8(scaled.to_luma8())
}
