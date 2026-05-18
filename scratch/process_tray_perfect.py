import os
from PIL import Image

def extract_only_cat_silhouette(input_path, output_path):
    print(f"Loading image from {input_path}...")
    img = Image.open(input_path).convert("RGBA")
    width, height = img.size
    pixels = img.load()
    assert pixels is not None
    
    # 1. Find a starting point (seed) near the center that has a bright/neon color
    # The container is extremely dark (luminance ~ 14), so a threshold of > 55 is perfect
    start_x, start_y = width // 2, height // 2
    found = False
    for r_offset in range(150):
        for dx in range(-r_offset, r_offset + 1):
            for dy in range(-r_offset, r_offset + 1):
                tx, ty = start_x + dx, start_y + dy
                if 0 <= tx < width and 0 <= ty < height:
                    r, g, b, a = pixels[tx, ty]  # type: ignore
                    lum = 0.299 * r + 0.587 * g + 0.114 * b
                    # If it's a bright or colored pixel (above 55), it's part of the cat face
                    if lum > 55:
                        start_x, start_y = tx, ty
                        found = True
                        break
            if found:
                break
        if found:
            break
            
    if not found:
        print("Warning: Could not find seed pixel near center. Defaulting to center.")
        start_x, start_y = width // 2, height // 2
        
    print(f"Starting flood fill inside cat silhouette at: ({start_x}, {start_y})")
    
    # 2. Perform BFS flood fill to isolate ONLY the connected bright cat shape (including neon parts)
    cat_pixels = set()
    queue = [(start_x, start_y)]
    cat_pixels.add((start_x, start_y))
    
    while queue:
        cx, cy = queue.pop(0)
        for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            nx, ny = cx + dx, cy + dy
            if 0 <= nx < width and 0 <= ny < height and (nx, ny) not in cat_pixels:
                r, g, b, a = pixels[nx, ny]  # type: ignore
                lum = 0.299 * r + 0.587 * g + 0.114 * b
                # The container boundary is very dark (lum ~ 14), so lum > 45 perfectly blocks leakage
                if lum > 45:
                    cat_pixels.add((nx, ny))
                    queue.append((nx, ny))
                    
    print(f"Isolated cat silhouette with {len(cat_pixels)} connected pixels.")
    
    # 3. Render the isolated cat shape fully solid (Alpha = 255) with smooth borders
    new_img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    new_pixels = new_img.load()
    assert new_pixels is not None
    
    for x, y in cat_pixels:
        r, g, b, a = pixels[x, y]  # type: ignore
        lum = 0.299 * r + 0.587 * g + 0.114 * b
        
        # Make the core shape fully solid (Alpha = 255) to prevent fading/half-visibility
        # Only anti-alias the absolute outer edges (lum between 45 and 65)
        if lum > 65:
            new_pixels[x, y] = (0, 0, 0, 255)  # type: ignore
        else:
            alpha = int(255 * min(1.0, max(0.0, (lum - 45) / 20.0)))
            if alpha > 10:
                new_pixels[x, y] = (0, 0, 0, alpha)  # type: ignore
            
    # 4. Crop to perfect cat silhouette bounding box
    bbox = new_img.getbbox()
    if bbox:
        new_img = new_img.crop(bbox)
        print("Cropped to perfect isolated cat silhouette.")
        
    # 5. Resize to high-quality standard tray size (32x32)
    size = (32, 32)
    final_img = new_img.resize(size, Image.Resampling.LANCZOS)
    
    # Save the processed image
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    final_img.save(output_path, "PNG")
    print(f"Successfully saved clean cat tray icon to {output_path}!")

if __name__ == "__main__":
    extract_only_cat_silhouette(
        "web/public/pwa-logo.png",
        "web/src-tauri/icons/tray-icon.png"
    )
