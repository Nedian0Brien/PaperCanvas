# Liquid Glass Morph 애니메이션 구현 가이드

Liquid Glass의 가장 특징적인 동작은 두 Glass 모양이 **물방울처럼 늘어지면서
하나로 합쳐졌다가 갈라지는 "모프(morph)" 애니메이션**이다.
이 문서는 SwiftUI에서 모프를 구현하는 방법과 PaperCanvas에서 사용 중인
세 가지 패턴(단순 모프 / 등장·소멸 모프 / 프레임 변형 모프)을 정리한다.

> 사전 지식: [Liquid Glass 디자인 구현 가이드](./LiquidGlass-Design.md)를 먼저
> 읽고 `glassEffect`, `Glass`, `buttonStyle(.glass)`에 익숙해진 뒤에 본다.

---

## 1. 모프란 무엇인가 — 페이드와 다른 점

일반적인 SwiftUI 전환(예: `.transition(.opacity)`)은 시작 뷰가 사라지면서 끝
뷰가 페이드 인되는 **불연속적인 교체**다. 시각적으로는 두 개의 다른 것이
타이밍을 어긋나며 교차할 뿐이다.

Liquid Glass의 모프는 다르다.

- **하나의 재질이 보존된 채로 모양만 변한다.** Glass 표면이 끊기지 않는다.
- 인접한 두 Glass 모양이 가까워지면 가장자리가 **장력처럼 연결**되어 한 덩어리가
  됐다가, 다시 멀어지면 갈라진다(물방울 합쳐짐과 같은 메타볼 효과).
- 굴절·반사가 애니메이션 프레임마다 다시 계산되어, 모프 도중에도 뒷배경이
  실시간으로 비친다.

이 효과를 켜려면 **세 가지가 모두** 필요하다.

1. 모프할 Glass 요소들을 `GlassEffectContainer`로 감싼다.
2. 각 요소에 `glassEffectID(_:in:)`로 정체성을 부여한다(`@Namespace` 필수).
3. 상태 변화를 `withAnimation { ... }` 안에서 일으킨다.

이 셋 중 하나라도 빠지면 모프는 일어나지 않고 평범한 페이드/스냅 전환이 된다.

---

## 2. 핵심 API

### 2.1 `GlassEffectContainer`

> 여러 Liquid Glass 모양을 **하나의 셰이프 집합**으로 묶어 함께 렌더링하고,
> 개별 모양끼리 모프할 수 있게 해 주는 컨테이너 뷰.

```swift
GlassEffectContainer(spacing: 40.0) {
    // 내부에 glassEffect를 가진 자식들
}
```

`spacing` 파라미터가 모프의 핵심이다.
- 두 Glass 모양의 거리가 `spacing` **이내로 들어오면** 가장자리가 서로
  당겨지면서 합쳐진다.
- `spacing`이 클수록 더 멀리서부터 모양이 연결되기 시작한다.
- **`spacing` 값은 자식 `HStack`/`VStack`의 spacing과 같은 값을 권장한다.**
  레이아웃 간격과 모프 임계값이 어긋나면 모양이 끊겨 보이거나 항상 붙어
  보인다.

성능: Glass는 다른 Glass를 샘플링하지 못한다. 같은 컨테이너로 묶으면 시스템이
한 번에 합쳐 렌더하므로 GPU 비용이 줄고, 합집합 셰이프(union)도 자동으로
생성된다.

### 2.2 `glassEffectID(_:in:)`

> 컨테이너 내 각 Glass 효과에 정체성을 부여한다. `@Namespace`와 함께 쓴다.

```swift
@Namespace private var namespace

Image(systemName: "scribble.variable")
    .glassEffect()
    .glassEffectID("pencil", in: namespace)
```

이 ID는 SwiftUI가 **"어느 모양이 어느 모양으로 모프해야 하는지"** 짝지을 때
쓰는 키다. 같은 id를 가진 두 뷰는 등장·소멸 시 서로 매칭된다. id가 다르면
서로 독립된 Glass로 취급돼 합집합/모프 후보가 되지 않는다.

> **중요한 함정:** `glassEffectID`는 **프레임을 보간하지 않는다.** Liquid Glass
> 요소의 합집합/분리(union/separation)만 관리한다. 만약 두 뷰가 서로 다른
> 레이아웃 컨테이너에 있어서 시작/끝 프레임이 다르면, 프레임 자체의 보간은
> `matchedGeometryEffect`가 함께 해 줘야 한다(아래 §6 참고).

### 2.3 `GlassEffectTransition`

> Glass 요소가 뷰 계층에 추가되거나 제거될 때 어떤 전환을 쓸지 결정한다.

```swift
SomeView()
    .glassEffect()
    .glassEffectTransition(.matchedGeometry)   // 기본
```

세 가지 변형:

| 케이스 | 동작 |
| --- | --- |
| `.matchedGeometry` | **기본값.** 등장하는 모양이 `spacing` 안의 다른 모양에서 솟아나듯 모프해 들어온다. 사라질 때도 가장 가까운 인접 모양으로 빨려 들어간다. |
| `.materialize` | 모프 대신 페이드 인/아웃. Glass 재질의 등장·소멸만 애니메이션. 모프가 과해 보일 때 톤다운 용도. |
| `.identity` | 효과 없음. 즉시 등장/소멸. |

**언제 바꾸나:**
- 작은 컨트롤이 잦은 빈도로 나타났다 사라질 때 모프가 산만하면
  `.materialize`로 낮춘다.
- 모달/시트처럼 명백히 다른 레이어로 들어오는 경우 모프가 어색하므로
  `.materialize`나 `.identity`.

### 2.4 `glassEffectUnion(id:namespace:)`

> 같은 id·namespace를 가진 여러 뷰의 Glass를 **하나의 합집합 모양**으로 묶는다.

```swift
let symbolSet: [String] = ["cloud.bolt.rain.fill", "sun.rain.fill",
                           "moon.stars.fill", "moon.fill"]

GlassEffectContainer(spacing: 20.0) {
    HStack(spacing: 20.0) {
        ForEach(symbolSet.indices, id: \.self) { item in
            Image(systemName: symbolSet[item])
                .frame(width: 80.0, height: 80.0)
                .font(.system(size: 36))
                .glassEffect()
                .glassEffectUnion(id: item < 2 ? "1" : "2", namespace: namespace)
        }
    }
}
```

위 예제는 앞 2개 아이콘, 뒤 2개 아이콘을 각각 하나의 캡슐로 합친다.
`ForEach`로 동적으로 만들어지는 요소나 레이아웃 컨테이너 바깥의 요소를
시각적으로 한 덩어리처럼 보이게 할 때 쓴다.

`glassEffectID`와의 차이:
- `glassEffectID` — **나타남/사라짐의 짝**을 매칭(모프).
- `glassEffectUnion` — **동시에 존재하는** 여러 모양을 **하나로 합집합**.

---

## 3. 가장 단순한 모프 — 단일 토글

Apple 공식 문서의 표준 예제. `isExpanded` 토글에 따라 eraser 아이콘이
scribble 옆에서 솟아나듯 모프해 들어왔다가 빨려 나간다.

```swift
@State private var isExpanded: Bool = false
@Namespace private var namespace

var body: some View {
    GlassEffectContainer(spacing: 40.0) {
        HStack(spacing: 40.0) {
            Image(systemName: "scribble.variable")
                .frame(width: 80.0, height: 80.0)
                .font(.system(size: 36))
                .glassEffect()
                .glassEffectID("pencil", in: namespace)

            if isExpanded {
                Image(systemName: "eraser.fill")
                    .frame(width: 80.0, height: 80.0)
                    .font(.system(size: 36))
                    .glassEffect()
                    .glassEffectID("eraser", in: namespace)
            }
        }
    }

    Button("Toggle") {
        withAnimation {
            isExpanded.toggle()
        }
    }
    .buttonStyle(.glass)
}
```

체크포인트:
- `GlassEffectContainer(spacing: 40.0)`와 `HStack(spacing: 40.0)`이 **같은 40**.
- 두 Glass 모두 같은 `namespace`, 그러나 **다른 id**("pencil", "eraser").
  → 두 모양은 합집합되지만, 사라질 때 다른 정체성으로 빨려 들어간다.
- 상태 변화는 반드시 `withAnimation`. 안 그러면 모프 안 됨.

---

## 4. 등장·소멸 모프 — 패널 전체 토글

Apple `Landmarks` 샘플의 패턴. 토글 버튼을 누르면 위쪽으로 뱃지들이 솟아 오르며
버튼 자체와 같은 Glass 덩어리에서 분리되는 효과.

```swift
GlassEffectContainer(spacing: Constants.badgeGlassSpacing) {
    VStack(alignment: .center, spacing: Constants.badgeButtonTopSpacing) {
        if isExpanded {
            VStack(spacing: Constants.badgeSpacing) {
                ForEach(modelData.earnedBadges) {
                    BadgeLabel(badge: $0)
                        .glassEffect(.regular, in: .rect(cornerRadius: Constants.badgeCornerRadius))
                        .glassEffectID($0.id, in: namespace)
                }
            }
        }

        Button {
            withAnimation {
                isExpanded.toggle()
            }
        } label: {
            ToggleBadgesLabel(isExpanded: isExpanded)
                .frame(width: Constants.badgeShowHideButtonWidth,
                       height: Constants.badgeShowHideButtonHeight)
        }
        .buttonStyle(.glass)
        #if os(macOS)
        .tint(.clear)
        #endif
        .glassEffectID("togglebutton", in: namespace)
    }
    .frame(width: Constants.badgeFrameWidth)
}
```

요점:
- `ForEach`로 생성되는 뱃지마다 **고유 id**(`$0.id`)를 부여 → 등장/소멸 매칭.
- 토글 버튼도 `glassEffectID("togglebutton", …)`로 합집합에 참여.
- `buttonStyle(.glass)` + `glassEffectID` 조합이 가능하다(직접 `glassEffect`를
  쓰지 않아도 됨).

---

## 5. 모프형 세그먼티드 컨트롤

선택 인디케이터가 옵션 사이를 **물방울처럼 미끄러져** 이동하는 패턴.
선택된 버튼만 `.prominent`로 강조, 나머지는 `.regular`로 두고 동일 namespace에서
id를 바꿔 가며 모프시킨다.

```swift
struct GlassSegmentedControl: View {
    @Binding var selection: Int
    let options: [String]
    @Namespace private var animation

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(options.indices, id: \.self) { index in
                        Button(options[index]) {
                            withAnimation(.smooth) {
                                selection = index
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassEffect(
                            selection == index ? .prominent.interactive()
                                               : .regular.interactive(),
                            in: .capsule
                        )
                        .glassEffectID(
                            selection == index ? "selected" : "option\(index)",
                            in: animation
                        )
                    }
                }
                .padding(4)
            }
        } else {
            Picker("Options", selection: $selection) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index]).tag(index)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}
```

트릭: 선택된 항목의 id를 항상 **`"selected"`로 고정**. 선택이 바뀔 때마다
새 인덱스가 "selected" id를 얻으므로 SwiftUI는 "selected" 모양이 위치만
바뀌었다고 인식하고 캡슐을 한 항목에서 다른 항목으로 모프시킨다.

---

## 6. 프레임 변형이 동반되는 모프 — `matchedGeometryEffect`와 함께

`glassEffectID`는 합집합/분리 정체성만 관리한다. 두 뷰의 **프레임 자체가 달라야
하는 경우**(예: 캡슐이 큰 패널로 펼쳐지는 경우) `glassEffectID`만으로는
프레임 보간이 일어나지 않아 모양이 뚝 점프한다.

이 때는 `matchedGeometryEffect`와 함께 사용한다. PaperCanvas의 문서 전환기
구현(`PaperCanvas/Features/Toolbar/SplitTopBar.swift`)이 정확히 이 패턴이다.

### 6.1 PaperCanvas 사례 — `SplitTopBar`

리딩(노트 식별자) 캡슐을 누르면 같은 자리에서 큰 그리드 패널로 펼쳐진다.
캡슐과 패널은 **프레임이 완전히 다르고 자식 구조도 다르다.**

```swift
@Namespace private var documentSwitcherNamespace

private var noteIdentity: some View {
    Group {
        if documentSwitcherKind == .note {
            // 펼쳐진 상태: 자리만 점유하고 실제 모양은 오버레이로
            noteIdentityContent
                .opacity(0)
                .accessibilityHidden(true)
                .overlay(alignment: .topLeading) {
                    morphedPanel(for: .note)
                        .matchedGeometryEffect(
                            id: DocumentSwitcherGlassID.note,
                            in: documentSwitcherNamespace
                        )
                        .fixedSize()
                }
        } else {
            // 캡슐 상태
            noteIdentityContent
                .glassEffect(.regular.interactive(), in: .capsule)
                .matchedGeometryEffect(
                    id: DocumentSwitcherGlassID.note,
                    in: documentSwitcherNamespace
                )
        }
    }
    .layoutPriority(2)
}

@ViewBuilder
private func morphedPanel(for kind: PaperDocumentKind) -> some View {
    DocumentSwitcherPanel(...)
        .glassEffect(.regular.interactive(),
                     in: .rect(cornerRadius: Radius.xl))
}
```

설계 의도(코드 주석 인용):
- `matchedGeometryEffect`가 **프레임 보간**을 담당. 시작(캡슐)과 끝(패널)의
  CGRect를 연결한다.
- `glassEffect`는 두 분기에 **각각 독립적으로** 적용. Glass 재질이 매 프레임
  현재 프레임에 맞춰 모양을 다시 그리도록 한다.
- 펼쳐졌을 때는 원래 캡슐 콘텐츠를 `opacity(0)`로 자리만 잡고, 실제
  보여지는 건 `overlay`의 패널 → 레이아웃 충돌 없이 캡슐 위치에서 패널이
  솟아 오른다.

전체 컨테이너:

```swift
var body: some View {
    GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
            leadingCluster
            Spacer(minLength: 0)
            trailingCluster
        }
    }
    .frame(maxWidth: .infinity, minHeight: TopBarMetrics.barHeight)
    .animation(Motion.indirectFast, value: documentSwitcherKind)
}
```

여기서도 `GlassEffectContainer(spacing: 8)`와 `HStack(spacing: 8)`가 같은 값이고,
상태 변화는 컨테이너 레벨의 `.animation(...)`이 처리한다.

### 6.2 언제 `glassEffectID`만으로 충분한가?

- 두 뷰의 **프레임 크기가 사실상 동일**(아이콘 크기, 패딩이 같은 캡슐 토글) →
  `glassEffectID`만으로 충분.
- 같은 `HStack`/`VStack` 안에서 한 항목이 자연스럽게 들어가거나 빠짐 →
  `glassEffectID`만으로 충분.

### 6.3 언제 `matchedGeometryEffect`까지 필요한가?

- 한 뷰가 다른 컨테이너로 **이동**하거나, 모양/크기가 **극적으로 다름**.
- 모프 도중 자식 콘텐츠 구성이 완전히 바뀜(텍스트 라벨 ↔ 그리드 패널).

> 한 줄 요약: **`glassEffectID`는 정체성, `matchedGeometryEffect`는 프레임.**

---

## 7. 애니메이션 트리거 — `withAnimation` 위치

모프가 일어나려면 상태 변화가 애니메이션 컨텍스트 안에서 일어나야 한다.
다음 셋 중 **하나**면 충분하다.

```swift
// (1) 상태 변화 호출부에 withAnimation
withAnimation(.smooth) {
    isExpanded.toggle()
}
```

```swift
// (2) 컨테이너에 .animation(_, value:) 부착
.animation(.smooth, value: isExpanded)
```

```swift
// (3) 부모에 .animation(_, value:) 부착 (값을 감시)
.animation(Motion.indirectFast, value: documentSwitcherKind)
```

PaperCanvas는 (3) 패턴을 쓴다 — 토글 액션 호출부는 단순 setter로 유지하고,
컨테이너 레벨에서 일관된 모션 토큰(`Motion.indirectFast`)으로 애니메이션을
적용한다. **모션 토큰을 한 곳에서 관리할 수 있다는 장점.**

권장 애니메이션:
- `.smooth` — Apple 샘플 기본값. 자연스러운 spring.
- `.snappy` — 더 빠르고 단단한 spring. 작은 토글에 적합.
- 명시적 `.spring(response:dampingFraction:)` — 모프 강도를 직접 제어.

`Reduce Motion` 환경에서는 시스템이 모프 강도를 자동으로 낮추지만, 모션 토큰
정의 시 환경 값을 한 번 더 가드하는 것이 안전하다.

---

## 8. 흔한 함정과 디버깅

### 8.1 "모프가 안 되고 페이드만 됨"

원인 1: 두 뷰가 **다른 `GlassEffectContainer`**에 있다. 같은 컨테이너로 모아야
모프 후보가 된다.

원인 2: `glassEffectID`의 namespace가 다르다. **반드시 같은 `@Namespace` 인스턴스**.

원인 3: 상태 변경이 `withAnimation` 밖이거나, 컨테이너에 `.animation(_, value:)`
부착이 없다.

### 8.2 "모양이 항상 붙어 있거나 항상 떨어져 있음"

`spacing` 값과 자식 레이아웃 spacing이 어긋남.
- 항상 붙어 있다 → 컨테이너 `spacing`이 자식 간격보다 너무 큼.
- 항상 떨어져 있다 → 너무 작음. 자식 간격과 같게 맞춘다.

### 8.3 "캡슐이 패널로 펼쳐질 때 프레임이 점프함"

`glassEffectID`만 썼다. §6의 `matchedGeometryEffect` 조합 필요.

### 8.4 "Glass가 다른 Glass 위에 깔리면 시커멓게 보임"

Glass는 다른 Glass를 샘플링하지 못한다. 두 Glass를 겹치려면 같은
`GlassEffectContainer` 안에 두거나, 둘 중 하나를 일반 `Material`로 바꾼다.

### 8.5 "모프 도중 콘텐츠가 깜빡임"

자식 콘텐츠가 분기마다 다른 뷰 타입이면 SwiftUI가 정체성을 잃는다.
- `id(...)` 모디파이어로 자식의 정체성을 명시.
- 혹은 PaperCanvas의 `SplitTopBar`처럼 한쪽을 `opacity(0)`로 자리만 잡고
  진짜 콘텐츠는 `overlay`로 띄워 두 분기의 자식 트리를 동일하게 유지.

### 8.6 "Preview에서는 모프가 잘 되는데 실기기에서 안 됨"

Reduce Motion이 켜져 있을 가능성 높음. 설정 → 손쉬운 사용 → 동작에서 확인.
이 경우 시스템이 모프를 의도적으로 약화시킨 것이므로 정상 동작.

---

## 9. PaperCanvas 모프 패턴 정리

| 사례 | 위치 | 패턴 |
| --- | --- | --- |
| 노트/캔버스 식별 캡슐 ↔ 그리드 패널 | `SplitTopBar.swift:69-79, 102-122, 197-217` | `GlassEffectContainer` + `matchedGeometryEffect` + 분기별 `glassEffect` (§6) |
| 상단바 3존(leading/tool/trailing)의 합집합 | `UnifiedTopBar.swift:71-78` | 단일 `GlassEffectContainer(spacing: zoneSpacing)`로 묶어 인접 모서리가 연결되도록 함 |
| 라이브러리/메뉴 트리거 버튼 | `SplitTopBar.swift:86-95`, `UnifiedTopBar.swift:175-177` | `buttonStyle(.glass)` + `buttonBorderShape(.capsule)` |
| 컨텍스트 우측 존 전환 | `UnifiedTopBar.swift:154-156` | `.animation(Motion.indirectFast, value: rightZoneContext)` — 컨텍스트가 PDF/Canvas로 바뀔 때 자식 컨트롤이 모프 |

---

## 10. 한 줄 정리

- **모프 = `GlassEffectContainer` + `glassEffectID(@Namespace)` + `withAnimation`**.
- `spacing`은 자식 레이아웃 간격과 동일하게.
- 프레임 자체가 다르면 `matchedGeometryEffect`를 같이 쓴다.
- 합집합만 필요하면 `glassEffectUnion`, 모프 강도 조절은 `glassEffectTransition`.
- 정적 요소엔 `.interactive()` 금지.

---

## 11. 참고

- Apple — [Applying Liquid Glass to custom views (Morph 섹션 포함)](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- Apple — [`GlassEffectContainer`](https://developer.apple.com/documentation/swiftui/glasseffectcontainer)
- Apple — [`glassEffectID(_:in:)`](https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:))
- Apple — [`glassEffectUnion(id:namespace:)`](https://developer.apple.com/documentation/swiftui/view/glasseffectunion(id:namespace:))
- Apple — [`GlassEffectTransition`](https://developer.apple.com/documentation/swiftui/glasseffecttransition)
- Apple — [`.matchedGeometry`](https://developer.apple.com/documentation/swiftui/glasseffecttransition/matchedgeometry)
- Apple — [`.materialize`](https://developer.apple.com/documentation/swiftui/glasseffecttransition/materialize)
- Apple — [Landmarks: Displaying custom activity badges (모프 뱃지 예제)](https://developer.apple.com/documentation/swiftui/landmarks-displaying-custom-activity-badges)
- WWDC25 — [Build a SwiftUI app with the new design (세션 323)](https://developer.apple.com/videos/play/wwdc2025/323/)
- WWDC25 — [Meet Liquid Glass (세션 219)](https://developer.apple.com/videos/play/wwdc2025/219/)
- Create with Swift — [Morphing glass effect elements into one another with glassEffectID](https://www.createwithswift.com/morphing-glass-effect-elements-into-one-another-with-glasseffectid/)
