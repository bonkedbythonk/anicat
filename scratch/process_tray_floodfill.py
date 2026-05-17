import os
from PIL import Image

def extract_cat_silhouette(input_path, output_path):
    print(f"Loading image from {input_path}...")
    img = Image.open(input_path).convert("RGBA")
    width, height = img.size
    
    # 1. Flood-fill to find the outer background (connected to corners)
    # The corner color is off-white (252, 252, 250)
    bg_color = (252, 252, 250)
    visited = set()
    queue = []
    
    # Start queue from all four corners
    corners = [
        (0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1),
        # Add some edge padding pixels to be safe
        (5, 5), (width - 6, 5), (5, height - 6), (width - 6, height - 6)
    ]
    for x, y in corners:
        if 0 <= x < width and 0 <= y < height:
            queue.append((x, y))
            visited.add((x, y))
            
    pixels = img.load()
    
    while queue:
        cx, cy = queue.pop(0)
        for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            nx, ny = cx + dx, cy + dy
            if 0 <= nx < width and 0 <= ny < height and (nx, ny) not in visited:
                r, g, b, a = pixels[nx, ny]
                dist = ((r - bg_color[0])**2 + (g - bg_color[1])**2 + (b - bg_color[2])**2)**0.5
                # If it's close to the background color (bright off-white), it's outer background
                if dist < 40 or (r > 235 and g > 235 and b > 235):
                    visited.add((nx, ny))
                    queue.append((nx, ny))
                    
    print(f"Flood fill identified {len(visited)} outer background pixels.")
    
    # 2. Create the new image containing ONLY the cat silhouette
    new_img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    new_pixels = new_img.load()
    
    for y in range(height):
        for x in range(width):
            if (x, y) in visited:
                # Outer background -> transparent
                new_pixels[x, y] = (0, 0, 0, 0)
            else:
                r, g, b, a = pixels[x, y]
                luminance = 0.299 * r + 0.587 * g + 0.114 * b
                
                # The squircle container is dark (luminance < 120)
                # The cat silhouette inside is bright (luminance > 120)
                if luminance < 130:
                    # Container -> transparent
                    new_pixels[x, y] = (0, 0, 0, 0)
                else:
                    # Cat shape! Make it solid black with a smooth anti-aliased alpha transition
                    # Calculate alpha based on how bright it is above the threshold
                    alpha = int(255 * min(1.0, max(0.0, (luminance - 130) / 40.0)))
                    if alpha > 10:
                        new_pixels[x, y] = (0, 0, 0, alpha)
                        
    # 3. Crop to the active bounding box of the cat silhouette
    bbox = new_img.getbbox()
    if bbox:
        new_img = new_img.crop(bbox)
        print("Cropped to isolated cat silhouette bounding box.")
        
    # 4. Resize to a standard high-quality tray size (32x32)
    size = (32, 32)
    final_img = new_img.resize(size, Image.Resampling.LANCZOS)
    
    # Save the processed image
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    final_img.save(output_path, "PNG")
    print(f"Successfully saved clean cat tray icon to {output_path}!")

if __name__ == "__main__":
    extract_cat_silhouette(
        "web/public/pwa-logo.png",
        "web/src-tauri/icons/tray-icon.png"
    )
