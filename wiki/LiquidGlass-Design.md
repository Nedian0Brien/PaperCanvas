# Apple Liquid Glass 디자인 구현 가이드

iOS 26 / iPadOS 26 / macOS Tahoe(26) / watchOS 26 / tvOS 26 / visionOS 26부터 도입된
Apple의 새 시각 언어 **Liquid Glass**를 SwiftUI에서 구현하는 방법을 정리한다.
이 문서는 PaperCanvas 프로젝트에서 실제로 어떻게 채택하고 있는지도 함께 다룬다.

---

## 1. Liquid Glass란

Liquid Glass는 컨트롤·내비게이션·플로팅 패널 등 "**크롬(chrome)**" 레이어를 위한
적응형 재질(material)이다. WWDC25에서 공개됐고, 다음 세 가지 특성을 가진다.

1. **굴절/반사** — 뒤에 깔린 콘텐츠를 광학적으로 굴절시키며 주변 색을 흡수한다.
2. **유체성(fluidity)** — 모양이 고정돼 있지 않고, 인접한 다른 Glass 요소와
   "**모프(morph)**"하면서 한 덩어리처럼 합쳐졌다 갈라진다.
3. **적응성(adaptive)** — 다크/라이트, 콘텐츠 톤, 접근성 설정에 따라 시스템이
   자동으로 외형을 바꾼다(Reduce Transparency 시 더 불투명해지고, Increase
   Contrast 시 윤곽선이 강해지며, Reduce Motion 시 모프 강도가 줄어든다).

핵심 원칙은 "**hierarchy through depth**"다. 컨트롤의 중요도를 색·크기로 표현하지
않고 굴절·투명도·재질 깊이로 표현한다. 따라서 Liquid Glass는 본문(content)에는
쓰지 않고, **컨트롤 레이어**에만 적용한다.

> Liquid Glass는 iOS 26+ 전용 API다. iOS 17/18 같은 하위 OS에서는 `if #available`
> 가드와 `Material`(예: `.ultraThinMaterial`) 폴백을 함께 두는 것이 표준 패턴이다.
> PaperCanvas는 `deploymentTarget: iOS 17.0`이지만 디자인 시스템 레이어에서
> Liquid Glass API를 직접 호출한다(아래 "PaperCanvas 적용" 참고).

---

## 2. 핵심 API 한눈에 보기

| API | 역할 |
| --- | --- |
| `glassEffect(_:in:)` | 뷰 뒤에 Liquid Glass 모양을 깔고 전면 효과를 입힌다. |
| `Glass` (구조체) | 재질 변형. `.regular`, `.clear`, `.identity`, 그리고 인스턴스 메서드 `.tint(_:)`, `.interactive(_:)`. |
| `GlassEffectContainer` | 여러 Glass 모양을 한 셰이프로 합쳐 렌더링/모프하는 컨테이너. |
| `glassEffectID(_:in:)` | 컨테이너 내 Glass 요소의 정체성 부여. 모프 대상을 짝지을 때 필요. |
| `glassEffectUnion(id:namespace:)` | 같은 id·namespace를 가진 Glass 요소들을 하나의 모양으로 합집합. |
| `glassEffectTransition(_:)` | 추가/제거 시 어떤 전환을 쓸지(`.matchedGeometry`/`.materialize`/`.identity`). |
| `buttonStyle(.glass)` / `.glassProminent` | 버튼에 Liquid Glass를 즉시 적용. |
| `buttonBorderShape(.capsule)` | `.glass` 버튼의 모양을 캡슐로 강제. |

가용성: 위 API 전부 **iOS/iPadOS/macOS/tvOS/watchOS/visionOS 26.0+**.

---

## 3. 기본 적용 — `glassEffect(_:in:)`

가장 단순한 형태. 기본값은 `.regular` 재질과 `Capsule()` 모양이다.

```swift
Text("Hello, World!")
    .font(.title)
    .padding()
    .glassEffect()                                 // 기본: regular + Capsule
```

모양을 바꾸려면 `in:` 인자에 `Shape`를 넘긴다. 큰 카드/패널엔 캡슐이 어울리지
않으므로 둥근 사각형을 쓴다.

```swift
Text("Hello, World!")
    .font(.title)
    .padding()
    .glassEffect(in: .rect(cornerRadius: 16.0))    // 라운드 사각형
```

틴트와 인터랙티브를 결합한 풀 옵션 형태.

```swift
Text("Hello, World!")
    .font(.title)
    .padding()
    .glassEffect(.regular.tint(.orange).interactive())
```

### 3.1 `Glass` 구조체 변형

- `Glass.regular` — 기본 재질. 90% 이상의 컨트롤은 이걸로 충분하다.
- `Glass.clear` — 더 투명하게.
- `Glass.identity` — 글라스 효과를 무력화(분기에서 효과를 끄고 싶을 때).
- `.tint(_:)` — 강조용 컬러 틴트. 강하게 쓰지 말고 prominence 표시 용도로만.
- `.interactive(_ isEnabled: Bool = true)` — 터치/포인터 입력에 반응하는
  탄성 변형을 켠다. **탭 가능한 요소에만** 적용해야 한다.

### 3.2 시그니처

```swift
nonisolated
func glassEffect(
    _ glass: Glass = .regular,
    in shape: some Shape = DefaultGlassEffectShape()
) -> some View
```

`DefaultGlassEffectShape()`는 `Capsule`로 해석된다.

---

## 4. 버튼 스타일 — `.glass`

표준 `Button`에 Glass를 입히는 가장 빠른 방법. 직접 `glassEffect`를 붙이는 것보다
포커스·접근성 처리가 자동으로 들어가므로 **버튼에는 우선 `.glass` 스타일을 쓴다.**

```swift
Button("라이브러리", systemImage: "books.vertical") {
    onLibraryTap()
}
.buttonStyle(.glass)
.buttonBorderShape(.capsule)
```

옵션:
- `.glass` — 기본 Liquid Glass 버튼.
- `.glassProminent` — 강조 버튼(시스템 액센트 컬러 사용).
- `.glass(Glass)` — `Glass` 인스턴스를 직접 넘겨 틴트/인터랙티브 커스터마이즈.

tvOS에서는 포커스 여부와 무관하게 항상 Glass 효과가 적용된다.

---

## 5. 가용성 가드와 폴백

`glassEffect`는 iOS 26+ 전용이므로 하위 OS를 지원한다면 `if #available`로
분기해서 `Material` 기반 폴백을 둔다. SwiftUI 커뮤니티의 표준 패턴.

```swift
struct GlassCard: View {
    let title: String
    let subtitle: String

    var body: some View {
        if #available(iOS 26, *) {
            cardContent
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            cardContent
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

버튼도 동일.

```swift
if #available(iOS 26, *) {
    Button(action: action) {
        Image(systemName: icon).font(.title2).frame(width: 44, height: 44)
    }
    .glassEffect(.regular.interactive(), in: .circle)
} else {
    Button(action: action) {
        Image(systemName: icon).font(.title2).frame(width: 44, height: 44)
    }
    .background(.regularMaterial, in: Circle())
}
```

---

## 6. 접근성

Liquid Glass는 시스템이 접근성 설정에 맞춰 자동 적응하지만, **앱 코드도 같은
환경 값을 참조해서 보조적인 조정을 해야 한다.**

```swift
@Environment(\.accessibilityReduceTransparency) var reduceTransparency
@Environment(\.accessibilityReduceMotion) var reduceMotion
@Environment(\.accessibilityShowButtonShapes) var showButtonShapes
```

- **Reduce Transparency** — 시스템이 Glass를 더 불투명한 frosted로 자동 전환.
  앱 측에서는 텍스트 가독성을 위해 Glass 위 텍스트 컬러를 `Color.Ink.primary`로
  쓰고, 보조 텍스트 대비를 별도로 검증.
- **Reduce Motion** — 시스템이 모프 강도를 줄이지만, 앱 자체 애니메이션도
  `withAnimation(reduceMotion ? .none : .smooth) { ... }` 형태로 가드.
- **Increase Contrast** — 시스템이 윤곽선을 추가. 커스텀 `strokeBorder`로
  중복 외곽선을 그리지 말 것.
- **VoiceOver** — Glass 컨트롤이라도 의미는 똑같이 노출돼야 한다.
  `accessibilityLabel`을 빠뜨리지 말 것(`SplitTopBar.swift` 사례 참조).

---

## 7. HIG 지침 요약

1. **컨트롤 레이어에만** 적용한다. 본문, 카드 콘텐츠, PDF 페이지 같은 contents에
   Glass를 깔지 않는다.
2. **모양 일관성** — 한 화면에서 캡슐/원/둥근 사각형을 무작위로 섞지 말 것.
   PaperCanvas는 버튼·뱃지는 `Capsule`, 큰 패널/툴존은 `Radius.xl`의
   `RoundedRectangle`로 통일.
3. **인접 Glass는 컨테이너로 묶기** — Glass는 다른 Glass를 샘플링하지 못한다.
   여러 Glass가 한 영역에 있으면 반드시 `GlassEffectContainer`로 감싼다.
4. **틴트는 신중하게** — `.tint`는 prominence 신호용. 모든 컨트롤에 색을
   칠하면 위계가 무너진다.
5. **인터랙티브는 입력 가능 요소에만** — 정적 배지/라벨에 `.interactive()`를
   붙이지 말 것. 사용자가 누를 수 있다는 어포던스가 거짓이 된다.

---

## 8. PaperCanvas 적용 패턴

프로젝트의 디자인 시스템 토큰은 `PaperCanvas/DesignSystem/Tokens/Glass.swift`에
얇은 래퍼로 정의돼 있다. **재사용 가능한 모양은 토큰 함수로, 매번 다른
구성은 직접 `glassEffect` 호출.** 두 가지를 섞어 쓴다.

### 8.1 디자인 토큰 (`Glass.swift`)

```swift
extension View {
    func chromeGlassCapsule() -> some View {
        glassEffect(in: .capsule)
    }

    func chromeGlassRect(cornerRadius: CGFloat = Radius.xl) -> some View {
        glassEffect(in: .rect(cornerRadius: cornerRadius))
    }

    func chromeGlassCircle() -> some View {
        glassEffect(in: .circle)
    }

    func chromeGlassTinted(_ color: Color, in shape: some Shape = Capsule()) -> some View {
        glassEffect(.regular.tint(color), in: shape)
    }
}
```

원칙:
- **공용 모양은 메서드로 노출** — 화면 곳곳에서 `.chromeGlassCapsule()`만 호출하면
  외형이 자동으로 통일된다. 코너 반경, 재질 변형을 한 곳에서 바꿀 수 있다.
- **`.interactive()`는 토큰화하지 않음** — 의도적으로 호출부에서
  `glassEffect(.regular.interactive(), in: …)`를 직접 쓴다. 인터랙티브 여부는
  의미상의 결정이고, 잘못된 곳에 자동으로 붙는 걸 막기 위해서.

### 8.2 `GlassChip` 컴포넌트

내부에 콘텐츠를 받아 패딩 + 캡슐 Glass를 한 번에 적용하는 소형 래퍼.

```swift
struct GlassChip<Content: View>: View {
    let content: Content
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat

    init(horizontalPadding: CGFloat = Spacing.m,
         verticalPadding: CGFloat = Spacing.s,
         @ViewBuilder content: () -> Content) {
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .chromeGlassCapsule()
    }
}
```

### 8.3 실제 사용 — `UnifiedTopBar.swift`

상단바는 leading / tool / trailing 3개 존을 각각 Glass 캡슐/패널로 만들고
하나의 `GlassEffectContainer`에 묶는다. 컨테이너의 `spacing`은 존 간격과
정확히 일치시켜야 한다(아래 Morph 가이드 참고).

```swift
GlassEffectContainer(spacing: TopBarMetrics.zoneSpacing) {
    HStack(spacing: TopBarMetrics.zoneSpacing) {
        leadingZone(density: density)     // .chromeGlassCapsule()
        toolZone(density: density)        // .chromeGlassRect(cornerRadius: Radius.xl)
        trailingZone(density: density)    // 버튼들 .buttonStyle(.glass)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}
```

### 8.4 인터랙티브 컨트롤 패턴

라이브러리 버튼·메뉴 트리거 등 탭 가능한 요소에는 `.buttonStyle(.glass)`를 쓴다.
`buttonBorderShape(.capsule)`로 모양을 강제하면 시스템이 동적으로 적절한
hit target까지 잡아준다.

```swift
Button(action: onLibraryTap) {
    Image(systemName: "books.vertical")
        .font(AppType.toolGlyph)
        .frame(width: TopBarMetrics.buttonSize,
               height: TopBarMetrics.buttonSize)
        .contentShape(Rectangle())
}
.buttonStyle(.glass)
.buttonBorderShape(.capsule)
.accessibilityLabel("라이브러리")
```

문서 전환기 캡슐처럼 **버튼이 아니라 셀로 동작하는 영역**에는 `.glass` 스타일
대신 `.buttonStyle(.plain)`을 쓰고, 외곽에 직접 `glassEffect(.regular.interactive(), in: .capsule)`을 호출한다.

```swift
trailingClusterContent
    .glassEffect(.regular.interactive(), in: .capsule)
    .matchedGeometryEffect(id: DocumentSwitcherGlassID.canvas,
                           in: documentSwitcherNamespace)
```

이렇게 하면 캡슐 전체가 누름 반응(인터랙티브 변형)을 받으면서, 안쪽 자식
컴포넌트들의 레이아웃을 자유롭게 구성할 수 있다.

---

## 9. Do / Don't 체크리스트

### Do

- 인접한 Glass는 항상 `GlassEffectContainer`로 감싼다(렌더링 성능 + 모프).
- `.interactive()`는 탭 가능한 컨트롤에만.
- 컨테이너의 `spacing`과 자식 레이아웃의 spacing을 **같은 값**으로 맞춘다.
- 레이아웃 모디파이어(`padding`, `frame`) **다음에** `glassEffect`를 호출한다.
- 하위 OS 지원이 필요하면 `if #available(iOS 26, *)` + `Material` 폴백.
- 시트(`.sheet`)는 기본 Glass 배경을 그대로 둔다. `presentationBackground(_:)`를
  덮어쓰면 시스템 Glass가 꺼진다.

### Don't

- 모든 뷰에 Glass를 입히지 말 것. Glass는 chrome용이지 콘텐츠용이 아님.
- 정적 텍스트/배지에 `.interactive()` 붙이지 말 것.
- 코너 반경을 화면마다 다르게 쓰지 말 것. 디자인 토큰으로 통일.
- `GlassEffectContainer`를 무의미하게 중첩하지 말 것.
- 툴바 위에 어두운 배경을 직접 깔지 말 것. 스크롤 엣지 효과와 충돌한다.
- `glassEffect`를 `padding`/`frame`보다 **먼저** 호출하지 말 것. 모양이 깨진다.

---

## 10. 참고

- Apple — [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- Apple — [`glassEffect(_:in:)`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))
- Apple — [`GlassEffectContainer`](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)
- Apple — [`Glass`](https://developer.apple.com/documentation/swiftui/glass)
- Apple — [`PrimitiveButtonStyle.glass`](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass)
- Apple — [Landmarks: Building an app with Liquid Glass](https://developer.apple.com/documentation/SwiftUI/Landmarks-Building-an-app-with-Liquid-Glass)
- Apple — [Landmarks: Refining the system provided Liquid Glass effect in toolbars](https://developer.apple.com/documentation/SwiftUI/Landmarks-Refining-the-system-provided-glass-effect-in-toolbars)
- Apple — [Liquid Glass(Technology Overview)](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- WWDC25 — [Meet Liquid Glass (세션 219)](https://developer.apple.com/videos/play/wwdc2025/219/)
- WWDC25 — [Build a SwiftUI app with the new design (세션 323)](https://developer.apple.com/videos/play/wwdc2025/323/)
- WWDC25 — [Get to know the new design system (세션 356)](https://developer.apple.com/videos/play/wwdc2025/356/)
