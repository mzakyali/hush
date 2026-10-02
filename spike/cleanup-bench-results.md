# Cleanup model bench (HUSH_BENCH=1) — round 2

Machine: Apple M1, 16 GB. Prompt = plan prompt with new self-correction rule + keep-content rule. Guard = CleanupGuard ratio + coverage (>0.75 strict, filler + droppable + corrected-away tokens excluded). Temperature 0.

"cached" = system-prompt prefix KV-cache reuse (prefill only user-turn tokens); "plain" = full re-prefill each call (ChatSession behaviour).

| # | model | pass | latency s | prefill s | decode s | prompt tok | cached tok | fellBack | coverage | final output |
|---|---|---|---|---|---|---|---|---|---|---|

### mlx-community/Qwen3-4B-Instruct-2507-4bit — MLXLLM (LLMModelFactory) — pass: plain

load: 6.4s

| 1 | mlx-community/Qwen3-4B-Instruct-2507-4bit | plain | 2.71 | 2.15 | 0.52 | 276 | 0 | false | 1.00 | Jadi besok kita deploy ke production ya, after lunch |
| 2 | mlx-community/Qwen3-4B-Instruct-2507-4bit | plain | 2.52 | 2.15 | 0.33 | 271 | 0 | true | 0.58 | um so I think we should, uh, move the meeting to Thursday, no, Friday at 3 |
| 3 | mlx-community/Qwen3-4B-Instruct-2507-4bit | plain | 3.59 | 2.38 | 1.17 | 289 | 0 | false | 1.00 | Jadi gini, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya |
| 4 | mlx-community/Qwen3-4B-Instruct-2507-4bit | plain | 2.97 | 2.17 | 0.77 | 274 | 0 | false | 1.00 | The three things we need are: the login page, the dashboard, and the settings screen. |
| 5 | mlx-community/Qwen3-4B-Instruct-2507-4bit | plain | 2.53 | 2.16 | 0.33 | 275 | 0 | false | 1.00 | Can you send me the report by tomorrow |
| 6 | mlx-community/Qwen3-4B-Instruct-2507-4bit | plain | 3.68 | 2.39 | 1.25 | 290 | 0 | true | 0.62 | eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng |

### mlx-community/Qwen3-4B-Instruct-2507-4bit — MLXLLM (LLMModelFactory) — pass: cached

| 1 | mlx-community/Qwen3-4B-Instruct-2507-4bit | cached | 3.99 | 0.94 | 1.08 | 32 | 244 | false | 1.00 | Jadi besok kita deploy ke production ya, after lunch |
| 2 | mlx-community/Qwen3-4B-Instruct-2507-4bit | cached | 1.08 | 0.59 | 0.44 | 37 | 234 | true | 0.58 | um so I think we should, uh, move the meeting to Thursday, no, Friday at 3 |
| 3 | mlx-community/Qwen3-4B-Instruct-2507-4bit | cached | 1.86 | 0.54 | 1.29 | 45 | 244 | false | 1.00 | Jadi gini, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya |
| 4 | mlx-community/Qwen3-4B-Instruct-2507-4bit | cached | 1.39 | 0.55 | 0.81 | 40 | 234 | false | 1.00 | The three things we need are: the login page, the dashboard, and the settings screen. |
| 5 | mlx-community/Qwen3-4B-Instruct-2507-4bit | cached | 2.65 | 0.32 | 0.34 | 24 | 251 | false | 1.00 | Can you send me the report by tomorrow |
| 6 | mlx-community/Qwen3-4B-Instruct-2507-4bit | cached | 2.03 | 0.55 | 1.44 | 46 | 244 | true | 0.62 | eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng |

phys_footprint after mlx-community/Qwen3-4B-Instruct-2507-4bit: 6.06 GB

### mlx-community/Qwen3-1.7B-4bit — MLXLLM (LLMModelFactory), enable_thinking=false — pass: plain

load: 43.2s

| 1 | mlx-community/Qwen3-1.7B-4bit | plain | 1.30 | 0.95 | 0.32 | 280 | 0 | false | 1.00 | eh jadi um besok kita deploy ke production ya, uh, after lunch |
| 2 | mlx-community/Qwen3-1.7B-4bit | plain | 1.36 | 0.94 | 0.39 | 275 | 0 | false | 1.00 | um so I think we should, uh, move the meeting to Thursday, no, Friday at 3 |
| 3 | mlx-community/Qwen3-1.7B-4bit | plain | 1.62 | 1.05 | 0.55 | 293 | 0 | false | 1.00 | jadi gini, eh, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya |
| 4 | mlx-community/Qwen3-1.7B-4bit | plain | 1.34 | 0.95 | 0.36 | 278 | 0 | false | 1.00 | okay the three things we need are first the login page second the dashboard and third the settings screen |
| 5 | mlx-community/Qwen3-1.7B-4bit | plain | 1.14 | 0.95 | 0.17 | 279 | 0 | false | 1.00 | can you send me the report by tomorrow |
| 6 | mlx-community/Qwen3-1.7B-4bit | plain | 1.66 | 1.05 | 0.59 | 294 | 0 | false | 1.00 | eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng |

### mlx-community/Qwen3-1.7B-4bit — MLXLLM (LLMModelFactory), enable_thinking=false — pass: cached

| 1 | mlx-community/Qwen3-1.7B-4bit | cached | 1.44 | 0.25 | 0.31 | 36 | 244 | false | 1.00 | eh jadi um besok kita deploy ke production ya, uh, after lunch |
| 2 | mlx-community/Qwen3-1.7B-4bit | cached | 0.67 | 0.24 | 0.42 | 41 | 234 | false | 1.00 | um so I think we should, uh, move the meeting to Thursday, no, Friday at 3 |
| 3 | mlx-community/Qwen3-1.7B-4bit | cached | 0.86 | 0.24 | 0.61 | 49 | 244 | false | 1.00 | jadi gini, eh, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya |
| 4 | mlx-community/Qwen3-1.7B-4bit | cached | 0.63 | 0.24 | 0.38 | 44 | 234 | false | 1.00 | okay the three things we need are first the login page second the dashboard and third the settings screen |
| 5 | mlx-community/Qwen3-1.7B-4bit | cached | 1.20 | 0.16 | 0.17 | 28 | 251 | false | 1.00 | can you send me the report by tomorrow |
| 6 | mlx-community/Qwen3-1.7B-4bit | cached | 0.86 | 0.24 | 0.61 | 50 | 244 | false | 1.00 | eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng |

phys_footprint after mlx-community/Qwen3-1.7B-4bit: 3.85 GB

## Raw outputs — mlx-community/Qwen3-4B-Instruct-2507-4bit [plain]

### input 1: eh jadi um besok kita deploy ke production ya, uh, after lunch

```
Jadi besok kita deploy ke production ya, after lunch
```

final: `Jadi besok kita deploy ke production ya, after lunch` (fellBack=false)

### input 2: um so I think we should, uh, move the meeting to Thursday, no, Friday at 3

```
move the meeting to Friday at 3
```

final: `um so I think we should, uh, move the meeting to Thursday, no, Friday at 3` (fellBack=true)

### input 3: jadi gini, eh, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya

```
Jadi gini, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya
```

final: `Jadi gini, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya` (fellBack=false)

### input 4: okay the three things we need are, um, first the login page, second the dashboard, and third the settings screen

```
The three things we need are: the login page, the dashboard, and the settings screen.
```

final: `The three things we need are: the login page, the dashboard, and the settings screen.` (fellBack=false)

### input 5: can you send me the report by tomorrow

```
Can you send me the report by tomorrow
```

final: `Can you send me the report by tomorrow` (fellBack=false)

### input 6: eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng

```
Meeting dengan client jadi hari Senin pukul sepuluh pagi, terus setelah itu kita makan siang bareng.
```

final: `eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng` (fellBack=true)


## Raw outputs — mlx-community/Qwen3-4B-Instruct-2507-4bit [cached]

### input 1: eh jadi um besok kita deploy ke production ya, uh, after lunch

```
Jadi besok kita deploy ke production ya, after lunch
```

final: `Jadi besok kita deploy ke production ya, after lunch` (fellBack=false)

### input 2: um so I think we should, uh, move the meeting to Thursday, no, Friday at 3

```
move the meeting to Friday at 3
```

final: `um so I think we should, uh, move the meeting to Thursday, no, Friday at 3` (fellBack=true)

### input 3: jadi gini, eh, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya

```
Jadi gini, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya
```

final: `Jadi gini, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya` (fellBack=false)

### input 4: okay the three things we need are, um, first the login page, second the dashboard, and third the settings screen

```
The three things we need are: the login page, the dashboard, and the settings screen.
```

final: `The three things we need are: the login page, the dashboard, and the settings screen.` (fellBack=false)

### input 5: can you send me the report by tomorrow

```
Can you send me the report by tomorrow
```

final: `Can you send me the report by tomorrow` (fellBack=false)

### input 6: eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng

```
Meeting dengan client jadi hari Senin pukul sepuluh pagi, terus setelah itu kita makan siang bareng.
```

final: `eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng` (fellBack=true)


## Raw outputs — mlx-community/Qwen3-1.7B-4bit [plain]

### input 1: eh jadi um besok kita deploy ke production ya, uh, after lunch

```
eh jadi um besok kita deploy ke production ya, uh, after lunch
```

final: `eh jadi um besok kita deploy ke production ya, uh, after lunch` (fellBack=false)

### input 2: um so I think we should, uh, move the meeting to Thursday, no, Friday at 3

```
um so I think we should, uh, move the meeting to Thursday, no, Friday at 3
```

final: `um so I think we should, uh, move the meeting to Thursday, no, Friday at 3` (fellBack=false)

### input 3: jadi gini, eh, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya

```
jadi gini, eh, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya
```

final: `jadi gini, eh, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya` (fellBack=false)

### input 4: okay the three things we need are, um, first the login page, second the dashboard, and third the settings screen

```
okay the three things we need are first the login page second the dashboard and third the settings screen
```

final: `okay the three things we need are first the login page second the dashboard and third the settings screen` (fellBack=false)

### input 5: can you send me the report by tomorrow

```
can you send me the report by tomorrow
```

final: `can you send me the report by tomorrow` (fellBack=false)

### input 6: eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng

```
eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng
```

final: `eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng` (fellBack=false)


## Raw outputs — mlx-community/Qwen3-1.7B-4bit [cached]

### input 1: eh jadi um besok kita deploy ke production ya, uh, after lunch

```
eh jadi um besok kita deploy ke production ya, uh, after lunch
```

final: `eh jadi um besok kita deploy ke production ya, uh, after lunch` (fellBack=false)

### input 2: um so I think we should, uh, move the meeting to Thursday, no, Friday at 3

```
um so I think we should, uh, move the meeting to Thursday, no, Friday at 3
```

final: `um so I think we should, uh, move the meeting to Thursday, no, Friday at 3` (fellBack=false)

### input 3: jadi gini, eh, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya

```
jadi gini, eh, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya
```

final: `jadi gini, eh, aku udah push branch-nya ke GitHub tapi CI-nya masih failed, nanti tolong di-review ya` (fellBack=false)

### input 4: okay the three things we need are, um, first the login page, second the dashboard, and third the settings screen

```
okay the three things we need are first the login page second the dashboard and third the settings screen
```

final: `okay the three things we need are first the login page second the dashboard and third the settings screen` (fellBack=false)

### input 5: can you send me the report by tomorrow

```
can you send me the report by tomorrow
```

final: `can you send me the report by tomorrow` (fellBack=false)

### input 6: eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng

```
eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng
```

final: `eh anu, meeting sama client-nya jadi hari Senin jam sepuluh pagi, terus habis itu kita lunch bareng` (fellBack=false)

