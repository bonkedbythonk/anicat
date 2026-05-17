import os
from PIL import Image

def process_logo_to_tray(input_path, output_path):
    print(f"Loading image from {input_path}...")
    img = Image.open(input_path).convert("RGBA")
    width, height = img.size
    
    # Create a new transparent image
    new_img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    
    # Get pixel data
    pixels = img.load()
    new_pixels = new_img.load()
    
    # We will identify the background color (around 252, 252, 250)
    bg_color = (252, 252, 250)
    
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[x, y]
            
            # Calculate distance to background color
            dist = ((r - bg_color[0])**2 + (g - bg_color[1])**2 + (b - bg_color[2])**2)**0.5
            
            # If the pixel is very close to white/off-white, make it transparent
            if dist < 25 or (r > 245 and g > 245 and b > 245):
                new_pixels[x, y] = (0, 0, 0, 0)
            else:
                # Convert the logo shape to black/greyscale.
                # A good way is to calculate the luminance of the pixel,
                # and map darker original pixels to darker black (higher opacity or solid black).
                # Since the logo is a colored shape on a white background,
                # we can make the foreground pure black to serve as a perfect macOS template icon.
                new_pixels[x, y] = (0, 0, 0, 255)
    
    # Crop to bounding box of non-transparent pixels to keep it centered and tight
    bbox = new_img.getbbox()
    if bbox:
        new_img = new_img.crop(bbox)
        print("Cropped image to active bounding box.")
        
    # Resize to standard high-res tray icon sizes:
    # macOS tray icon is ideally 22x22 points. 32x32 or 64x64 PNG works perfectly.
    # Let's save a 64x64 version to support high-DPI (Retina) screens.
    size = (32, 32)
    final_img = new_img.resize(size, Image.Resampling.LANCZOS)
    
    # Ensure parent directory exists
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    
    final_img.save(output_path, "PNG")
    print(f"Successfully processed and saved tray icon to {output_path}!")

if __name__ == "__main__":
    process_logo_to_tray(
        "web/public/pwa-logo.png",
        "web/src-tauri/icons/tray-icon.png"
    )
