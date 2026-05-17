# PaperCanvas Wiki

PaperCanvas 프로젝트의 디자인·구현 가이드 문서를 모아 두는 곳.

## 디자인 시스템 / Liquid Glass

- [Liquid Glass 디자인 구현 가이드](./LiquidGlass-Design.md)
  - iOS 26+ Liquid Glass의 개념, `glassEffect`/`Glass`/`buttonStyle(.glass)` 사용법,
    모양·틴트·인터랙티브 옵션, 접근성, 가용성 가드, PaperCanvas 적용 패턴
- [Liquid Glass Morph 애니메이션 구현 가이드](./LiquidGlass-Morph.md)
  - `GlassEffectContainer` + `glassEffectID` + `@Namespace`로 만드는 모프 애니메이션,
    `GlassEffectTransition`(`matchedGeometry`/`materialize`), `glassEffectUnion`,
    프레임 변형 시 `matchedGeometryEffect`와의 조합 패턴, 흔한 함정

## 참고 출처

문서 본문 하단의 "참고" 섹션에 Apple 공식 문서·WWDC25 세션 링크를 정리해 두었음.
