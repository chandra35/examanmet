import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

// Simple PNG generator for app icon
// Creates a 1024x1024 green icon with "EM" text pattern

void main() {
  final size = 1024;
  
  // Create RGBA pixel data
  final pixels = Uint8List(size * size * 4);
  
  // Background: Dark green gradient
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final idx = (y * size + x) * 4;
      
      // Gradient from dark green to slightly lighter
      final gradientFactor = y / size;
      final r = (0x1B * (1 - gradientFactor * 0.3)).round();
      final g = (0x5E + (0x20 * gradientFactor)).round().clamp(0, 255);
      final b = (0x20 * (1 - gradientFactor * 0.2)).round();
      
      pixels[idx] = r;     // R
      pixels[idx + 1] = g; // G
      pixels[idx + 2] = b; // B
      pixels[idx + 3] = 255; // A
      
      // Draw a shield/book shape in center
      final cx = size / 2;
      final cy = size / 2;
      final dx = (x - cx).abs();
      final dy = (y - cy).abs();
      
      // Shield shape
      if (dx < size * 0.35 && dy < size * 0.38) {
        final shieldBottom = size * 0.38 * (1 - (dx / (size * 0.35)) * (dx / (size * 0.35)));
        if (y < cy + shieldBottom && y > cy - size * 0.38) {
          // Lighter green for shield
          pixels[idx] = 0x2E;
          pixels[idx + 1] = 0x7D;
          pixels[idx + 2] = 0x32;
        }
      }
      
      // Inner circle for "EM" area
      final dist = sqrt(dx * dx + dy * dy);
      if (dist < size * 0.22 && dist > size * 0.19) {
        // White circle border
        pixels[idx] = 255;
        pixels[idx + 1] = 255;
        pixels[idx + 2] = 255;
      }
      
      if (dist < size * 0.19) {
        // Dark area for text background
        pixels[idx] = 0x0D;
        pixels[idx + 1] = 0x47;
        pixels[idx + 2] = 0x0D;
      }
    }
  }
  
  // Draw "E" letter (left side of center)
  _drawLetter(pixels, size, 'E', size ~/ 2 - 90, size ~/ 2);
  // Draw "M" letter (right side of center)  
  _drawLetter(pixels, size, 'M', size ~/ 2 + 30, size ~/ 2);
  
  // Encode as PNG
  final png = _encodePNG(pixels, size, size);
  
  // Write both files
  File('assets/icon/app_icon.png').writeAsBytesSync(png);
  File('assets/icon/app_icon_foreground.png').writeAsBytesSync(png);
  
  print('Icons generated successfully!');
}

void _drawLetter(Uint8List pixels, int size, String letter, int startX, int centerY) {
  final letterHeight = 120;
  final letterWidth = 80;
  final thickness = 18;
  final topY = centerY - letterHeight ~/ 2;
  
  void fillRect(int x1, int y1, int x2, int y2) {
    for (int y = y1; y < y2; y++) {
      for (int x = x1; x < x2; x++) {
        if (x >= 0 && x < size && y >= 0 && y < size) {
          final idx = (y * size + x) * 4;
          pixels[idx] = 255;     // White
          pixels[idx + 1] = 255;
          pixels[idx + 2] = 255;
          pixels[idx + 3] = 255;
        }
      }
    }
  }
  
  if (letter == 'E') {
    // Vertical bar
    fillRect(startX, topY, startX + thickness, topY + letterHeight);
    // Top bar
    fillRect(startX, topY, startX + letterWidth, topY + thickness);
    // Middle bar
    fillRect(startX, centerY - thickness ~/ 2, startX + letterWidth - 10, centerY + thickness ~/ 2);
    // Bottom bar
    fillRect(startX, topY + letterHeight - thickness, startX + letterWidth, topY + letterHeight);
  } else if (letter == 'M') {
    // Left vertical
    fillRect(startX, topY, startX + thickness, topY + letterHeight);
    // Right vertical
    fillRect(startX + letterWidth - thickness, topY, startX + letterWidth, topY + letterHeight);
    // Left diagonal (simplified as vertical bars)
    for (int i = 0; i < letterHeight ~/ 2; i++) {
      int x = startX + thickness + (i * (letterWidth ~/ 2 - thickness)) ~/ (letterHeight ~/ 2);
      fillRect(x, topY + i, x + thickness ~/ 2, topY + i + 2);
    }
    // Right diagonal
    for (int i = 0; i < letterHeight ~/ 2; i++) {
      int x = startX + letterWidth - thickness - (i * (letterWidth ~/ 2 - thickness)) ~/ (letterHeight ~/ 2);
      fillRect(x, topY + i, x + thickness ~/ 2, topY + i + 2);
    }
  }
}

// Minimal PNG encoder
Uint8List _encodePNG(Uint8List pixels, int width, int height) {
  // PNG signature
  final signature = [137, 80, 78, 71, 13, 10, 26, 10];
  
  // IHDR chunk
  final ihdr = BytesBuilder();
  ihdr.add(_uint32BE(width));
  ihdr.add(_uint32BE(height));
  ihdr.addByte(8); // bit depth
  ihdr.addByte(6); // color type (RGBA)
  ihdr.addByte(0); // compression
  ihdr.addByte(0); // filter
  ihdr.addByte(0); // interlace
  final ihdrChunk = _makeChunk('IHDR', ihdr.toBytes());
  
  // IDAT chunk - raw pixel data with filter bytes
  final rawData = BytesBuilder();
  for (int y = 0; y < height; y++) {
    rawData.addByte(0); // filter: none
    final rowStart = y * width * 4;
    rawData.add(pixels.sublist(rowStart, rowStart + width * 4));
  }
  
  // Compress with zlib (deflate)
  final compressed = ZLibCodec().encode(rawData.toBytes());
  final idatChunk = _makeChunk('IDAT', Uint8List.fromList(compressed));
  
  // IEND chunk
  final iendChunk = _makeChunk('IEND', Uint8List(0));
  
  // Combine all
  final png = BytesBuilder();
  png.add(signature);
  png.add(ihdrChunk);
  png.add(idatChunk);
  png.add(iendChunk);
  
  return png.toBytes();
}

Uint8List _uint32BE(int value) {
  return Uint8List(4)
    ..[0] = (value >> 24) & 0xFF
    ..[1] = (value >> 16) & 0xFF
    ..[2] = (value >> 8) & 0xFF
    ..[3] = value & 0xFF;
}

Uint8List _makeChunk(String type, Uint8List data) {
  final chunk = BytesBuilder();
  chunk.add(_uint32BE(data.length));
  final typeBytes = type.codeUnits;
  chunk.add(typeBytes);
  chunk.add(data);
  
  // CRC32
  final crcData = BytesBuilder();
  crcData.add(typeBytes);
  crcData.add(data);
  chunk.add(_uint32BE(_crc32(crcData.toBytes())));
  
  return chunk.toBytes();
}

int _crc32(Uint8List data) {
  int crc = 0xFFFFFFFF;
  for (int byte in data) {
    crc ^= byte;
    for (int j = 0; j < 8; j++) {
      if ((crc & 1) == 1) {
        crc = (crc >> 1) ^ 0xEDB88320;
      } else {
        crc >>= 1;
      }
    }
  }
  return crc ^ 0xFFFFFFFF;
}
