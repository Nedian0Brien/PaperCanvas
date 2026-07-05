<div align="center">

# PaperCanvas

**iPad에서 논문 PDF와 무한 캔버스 노트를 나란히 다루는 리딩 앱**

![Swift 5.9](https://img.shields.io/badge/Swift_5.9-F05138?style=flat-square&logo=swift&logoColor=white) ![iOS 17+](https://img.shields.io/badge/iOS_17+-000000?style=flat-square&logo=apple&logoColor=white) ![SwiftUI](https://img.shields.io/badge/SwiftUI-0A84FF?style=flat-square&logo=swift&logoColor=white) ![PDFKit](https://img.shields.io/badge/PDFKit-6B7280?style=flat-square)

[English](./README.en.md)

</div>

---

## 소개

PaperCanvas는 논문 PDF를 읽으면서 핵심 텍스트와 이미지 영역을 우측 캔버스로 옮기고, Apple Pencil 기반 필기와 출처 링크를 함께 유지하는 iPad 전용 노트 앱입니다.

현재 저장소에는 SwiftUI 앱 구조, PDFKit 기반 뷰어, PencilKit/Metal 기반 잉크 렌더링, Liquid Glass 디자인 문서와 샘플 PDF가 포함되어 있습니다.

## 주요 기능

| 기능 | 설명 |
|---|---|
| 분할 리딩 화면 | 좌측 PDF 뷰어와 우측 자유 캔버스를 함께 사용하는 구조입니다. |
| PDF 스크랩 | 텍스트, 이미지, 수식 영역을 캔버스 객체로 옮기고 원문 위치로 돌아갈 수 있는 출처 링크를 유지하는 방향입니다. |
| 무한 캔버스 | 필기와 스크랩 객체가 화면 경계 밖으로 확장되는 자유 노트 공간을 지향합니다. |
| 네이티브 필기 | PencilKit과 자체 잉크 렌더링 경로를 사용합니다. |
| Liquid Glass 디자인 | iOS 26+ Liquid Glass 가이드와 morph 애니메이션 메모를 wiki에 보관합니다. |

## 저장소 구조

| 경로 | 역할 |
|---|---|
| PaperCanvas/App/ | SwiftUI app entry and shell views |
| PaperCanvas/Features/PDFViewer/ | PDFKit viewer, anchors, overlays, page navigation |
| PaperCanvas/Features/Canvas/ | Canvas, tile grid, scrap overlays, drag preview |
| PaperCanvas/Features/InkEngine/ | Metal/PencilKit ink rendering implementation |
| wiki/ | Design-system and Liquid Glass implementation notes |

## 빠른 시작

### Xcode에서 열기

```bash
open PaperCanvas.xcodeproj
```

### 프로젝트 설정 확인

```bash
sed -n "1,120p" project.yml
```

### 시뮬레이터 실행

```bash
Xcode에서 iPad simulator를 선택한 뒤 Run
```

## 검증

| 항목 | 명령 |
|---|---|
| Project file exists | `test -d PaperCanvas.xcodeproj` |
| Project config exists | `test -f project.yml` |

## 운영 메모

- 기준 플랫폼은 iOS 17.0 이상, iPad target입니다.
- PDF 필기 경로는 screen-space 기반 `PDFInkRenderView`와 gesture recognizer 경로를 기준으로 유지합니다.
- 새 UI는 기존 DesignSystem/Tokens와 wiki의 Liquid Glass 지침을 먼저 확인합니다.

## 문서 작성 근거

이 README는 저장소 안의 다음 파일과 문서를 기준으로 작성했습니다.

- `project.yml`
- `[기획서] 아이패드 논문 리딩 최적화 노트 앱 (가칭: PaperCanvas).md`
- `wiki/README.md`
- `AGENTS.md`
