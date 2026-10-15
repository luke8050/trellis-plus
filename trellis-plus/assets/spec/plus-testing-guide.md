# Unit Testing Guide (Java 8 + Maven + JUnit 5 + Mockito)

> Added by trellis-plus. Enforced by `node .trellis/plus/gate.mjs test`.
> Mockito: stay on 4.x with Java 8 (Mockito 5 requires Java 11). JUnit 5.x supports Java 8.

## Rule

Every Service and Controller class you add or modify gets a unit test added or updated **in the same change**. No exceptions without an entry in `implement.md` → "Test Exemptions" (path + reason) that the user has seen.

## Location and naming

| Production class | Test class |
|---|---|
| `src/main/java/a/b/FooService.java` | `src/test/java/a/b/FooServiceTest.java` |
| `.../FooServiceImpl.java` | `FooServiceImplTest` (or `FooServiceTest` if it tests the interface contract) |
| `.../FooController.java` | `FooControllerTest` |

Method names: `method_scenario_expectedResult` (e.g. `create_duplicateOrderNo_throwsBizException`).

## What each public method needs

At least one test for each of: **normal path**, **boundary** (null/empty/limit/first/last), **error path** (each thrown exception / failure branch you added or touched). Changed behavior → update the existing test, do not delete it. Bug fix → add the regression test that fails without the fix.

## Service tests — no Spring context

```java
@ExtendWith(MockitoExtension.class)
class FooServiceTest {
    @Mock private FooMapper fooMapper;
    @InjectMocks private FooService service;

    @Test
    void create_valid_savesAndReturnsId() {
        when(fooMapper.insert(any())).thenReturn(1);
        Long id = service.create(validDto());
        assertNotNull(id);
        verify(fooMapper).insert(argThat(e -> "x".equals(e.getName())));
    }
}
```

- Mock only collaborators (mapper/client/other service); never mock the class under test.
- Assert results AND side effects (`verify` with argument matchers, `verifyNoMoreInteractions` where it matters).
- Assert the exception type and message/code, not just that something is thrown (`assertThrows`).
- Use `ArgumentCaptor` for objects built inside the method.

## Controller tests — MockMvc standalone (fast, no context)

```java
@ExtendWith(MockitoExtension.class)
class FooControllerTest {
    @Mock private FooService fooService;
    @InjectMocks private FooController controller;
    private MockMvc mvc;

    @BeforeEach void setUp() { mvc = MockMvcBuilders.standaloneSetup(controller).build(); }

    @Test
    void get_found_returns200AndBody() throws Exception {
        when(fooService.find(1L)).thenReturn(dto());
        mvc.perform(get("/foo/1")).andExpect(status().isOk()).andExpect(jsonPath("$.id").value(1));
        verify(fooService).find(1L);
    }
}
```

Cover: status code, response body fields, validation failure (400), service exception mapping, and that the right service method is called with the right arguments. If the project already uses `@WebMvcTest`, follow that instead (check existing tests first).

## Don'ts

- No `Thread.sleep`, real network/DB, system clock or random without injection.
- No tests without assertions; no `@Disabled` to make the gate pass; no `try/catch` that swallows failures.
- Do not weaken production code visibility only to test it.

## Commands

```bash
mvn -q test -Dtest=FooServiceTest,FooControllerTest -Dsurefire.failIfNoSpecifiedTests=false
mvn -q test            # full suite before the final commit when the change is wide
```
