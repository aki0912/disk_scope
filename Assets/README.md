# アプリアイコン

採用案は「虫眼鏡＋容量マップ」。内蔵の画像生成ツールで生成したC案を、デザインを変えずに使用しています。

- `AppIcon.png`: 透過背景付きの元画像。
- `../scripts/build-icon.sh`: macOS標準の `sips` と `iconutil` で16〜1024 pxの各サイズを生成し、`build/AppIcon.icns` にまとめます。
- `../scripts/build.sh`: アイコンをアプリの `Contents/Resources/` に同梱して署名します。

生成時のプロンプト:

```text
Use case: logo-brand.
Asset type: original macOS desktop app icon concept for DiskScope, a fast local SSD disk-space visualizer. Its main feature is a treemap, where unequal rectangle areas represent file sizes. The existing app is dark navy with mint-green accents and teal, lavender, blue and rose file-category colors.
Composition: one centered app icon, square image, macOS rounded-square silhouette occupying about 84 percent of the canvas, front facing, consistent generous outer padding. Transparent outside the rounded-square icon. A refined, simple, carefully balanced icon that remains recognizable at 32 pixels. Beautiful restrained depth and crisp geometry. Professional desktop utility, calm and precise. No title, no letters, no captions, no numbers, no watermark. This is an icon asset, not a device mockup or screenshot.
Concept C — Scope. A rich deep-teal rounded-square base. A bold single mint circular inspection lens with a short thick handle angled toward the lower right, beautifully integrated over a small area map. Inside the lens are four unequal rectangular blocks in mint, pale blue, lavender and teal, clearly suggesting inspecting disk usage. Use generous dark negative space, crisp thick shapes, restrained glass translucency only in the circular lens. The lens is the dominant recognizable silhouette. No extra circles or decorative rings, no charts or crosshairs.
```
