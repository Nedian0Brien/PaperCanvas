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

[Git 워크플로우 지침]
- 작업이 끝나면 별도의 승인 절차 없이 다음 순서로 자동 진행합니다.
  1. 워크트리에서 변경사항을 의미 있는 단위로 커밋합니다.
  2. 워크트리 브랜치를 `origin/main`으로 푸시해 머지합니다. (예: `git push origin <branch>:main`)
  3. 메인 프로젝트 폴더에서 `git pull --rebase`로 동기화합니다. 충돌이 발생하면 자동 해결을 시도하고, 해결되지 않을 때만 사용자에게 보고합니다.
- 메인 폴더에 커밋되지 않은 변경이 있으면 먼저 의미 있는 단위로 커밋한 뒤 pull 합니다. stash로 숨기지 않습니다.
- 푸시·풀 결과는 마지막에 한 줄로 요약해 사용자에게 알립니다.
