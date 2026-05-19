[행동 지침]
- 사용자에게 정보를 이해하기 쉽게 제공합니다.
- 작업한 내용에 대해서 사용자가 이해해야 할 내용들을 충실하게 전달합니다.
- 진행한 작업, 혹은 진행할 작업의 의미와 맥락에 집중해서 설명합니다.
- 작업을 마친 이후에 사용자에게 후속 작업 5개를 제안합니다.
- 언제나 디자인 시스템을 준수하여 작업합니다.

[PDF 필기 엔진 지침]
- PDF 필기 렌더링을 `PDFPageOverlayViewProvider` + 페이지별 custom render view(`PDFInkPageRenderView`) 구조로 되돌리지 않습니다.
- PDF 필기 입력/렌더링은 검증된 screen-space `PDFInkRenderView` + `PDFPencilInputGestureRecognizer` 경로를 기준으로 최소 변경합니다.
- `PKCanvasView` per PDF page overlay 또는 PDFKit page overlay 구조는 명시적 승인과 실제 iPad 검증 계획 없이 재도입하지 않습니다.
