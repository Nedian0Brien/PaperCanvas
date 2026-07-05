<div align="center">

# PaperCanvas

**An iPad reading app that pairs PDF papers with an infinite note canvas**

![Swift 5.9](https://img.shields.io/badge/Swift_5.9-F05138?style=flat-square&logo=swift&logoColor=white) ![iOS 17+](https://img.shields.io/badge/iOS_17+-000000?style=flat-square&logo=apple&logoColor=white) ![SwiftUI](https://img.shields.io/badge/SwiftUI-0A84FF?style=flat-square&logo=swift&logoColor=white) ![PDFKit](https://img.shields.io/badge/PDFKit-6B7280?style=flat-square)

[한국어](./README.md)

</div>

---

## Overview

PaperCanvas is an iPad-first research reading app for working with PDFs and a free-form canvas side by side. It focuses on extracting text or regions from a paper, arranging them on a canvas, and keeping links back to the original source.

The repository contains the SwiftUI app shell, PDFKit viewer code, PencilKit/Metal ink paths, Liquid Glass design notes, and sample PDFs.

## Highlights

| Area | Description |
|---|---|
| Split reading layout | The app is built around a PDF viewer on one side and a free-form note canvas on the other. |
| PDF scraps | Text, image, and region scraps can become canvas objects while preserving their source location. |
| Infinite canvas | The note space is designed to expand naturally as reading notes grow. |
| Native ink | PencilKit and custom ink rendering paths support handwriting and annotation. |
| Liquid Glass design notes | The wiki tracks iOS Liquid Glass implementation and morph animation guidance. |

## Repository Structure

| Path | Role |
|---|---|
| PaperCanvas/App/ | SwiftUI app entry and shell views |
| PaperCanvas/Features/PDFViewer/ | PDFKit viewer, anchors, overlays, page navigation |
| PaperCanvas/Features/Canvas/ | Canvas, tile grid, scrap overlays, drag preview |
| PaperCanvas/Features/InkEngine/ | Metal/PencilKit ink rendering implementation |
| wiki/ | Design-system and Liquid Glass implementation notes |

## Quick Start

### Open in Xcode

```bash
open PaperCanvas.xcodeproj
```

### Inspect project settings

```bash
sed -n "1,120p" project.yml
```

### Run on simulator

```bash
Choose an iPad simulator in Xcode and press Run
```

## Verification

| Check | Command |
|---|---|
| Project file exists | `test -d PaperCanvas.xcodeproj` |
| Project config exists | `test -f project.yml` |

## Operational Notes

- The target platform is iPad on iOS 17.0 or later.
- PDF ink work should preserve the validated screen-space PDF ink rendering path.
- New UI work should check DesignSystem tokens and the Liquid Glass wiki notes first.

## Documentation Sources

This README was written from the following files and documents in this repository.

- `project.yml`
- `[기획서] 아이패드 논문 리딩 최적화 노트 앱 (가칭: PaperCanvas).md`
- `wiki/README.md`
- `AGENTS.md`
