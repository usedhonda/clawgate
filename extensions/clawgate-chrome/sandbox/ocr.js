function loadImage(source) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error('Image decode failed'));
    image.src = source;
  });
}

function createOCRCanvas(image) {
  const maxDimension = 1600;
  const scale = Math.min(1, maxDimension / Math.max(image.width, image.height));
  const width = Math.max(1, Math.round(image.width * scale));
  const height = Math.max(1, Math.round(image.height * scale));

  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext('2d', { willReadFrequently: true });
  context.drawImage(image, 0, 0, width, height);

  const frame = context.getImageData(0, 0, width, height);
  const data = frame.data;
  for (let i = 0; i < data.length; i += 4) {
    const gray = Math.round((data[i] * 0.299) + (data[i + 1] * 0.587) + (data[i + 2] * 0.114));
    const boosted = gray > 168 ? 255 : gray < 88 ? 0 : gray;
    data[i] = boosted;
    data[i + 1] = boosted;
    data[i + 2] = boosted;
  }
  context.putImageData(frame, 0, 0);
  return canvas;
}

async function runOCR(imageDataUrl) {
  if (typeof OCRAD !== 'function') {
    throw new Error('OCRAD unavailable');
  }
  const image = await loadImage(imageDataUrl);
  const canvas = createOCRCanvas(image);
  return OCRAD(canvas) || '';
}

window.addEventListener('message', async (event) => {
  const data = event.data;
  if (!data || data.type !== 'clawgate_ocr_request' || typeof data.id !== 'string') {
    return;
  }

  try {
    const text = await runOCR(data.imageDataUrl);
    event.source?.postMessage({
      type: 'clawgate_ocr_result',
      id: data.id,
      ok: true,
      text,
    }, event.origin);
  } catch (error) {
    event.source?.postMessage({
      type: 'clawgate_ocr_result',
      id: data.id,
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    }, event.origin);
  }
});
