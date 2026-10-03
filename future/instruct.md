# instruct

[instruct.ttl](./instruct.ttl) is an experimental ontology. It states the basic concepts of an abstract computational model, a small virtual machine, in RDF, so that Arspec's multi-perspective way of representing data can be put to work on programs.

Everything in this folder is a look ahead and a testing ground for Arspec. None of it is part of a release.

## Rationale

### Two domains, one of them hidden

Any computer program, and any computer, consists of two orthogonal domains:

- **state**: memory, caches, processor registers;
- **instructions**: what the CPU or the VM executes to move that state from one phase to the next.

The distinction is well known. It is built into the hardware. Yet nearly every modern programming language and model, probably starting with Algol, makes a noticeable effort to hide it from the programmer or to soften it, one way or another.

It was an understandable goal. For decades programs have been stored and edited as one-dimensional text. In a linear text it is hard to move between separate domains or layers, to follow every nuance of how pieces of state relate, and still be sure the program is robust and maintainable. Something had to give, and as far as I can see it was always state. The domain of state management was diminished, or made subordinate to the domain of instructions, so that programs would be simpler to write down. The true complexity of a program's state did not go away. It was wrapped in helper concepts that are convenient only up to a point:

- **The procedure call stack.** State is created and discarded as a side effect of control flow, and a function knows nothing of the frames beneath its own.
- **Object-oriented programming.** State is hidden behind the methods that touch it. Who owns an object, and who else holds a reference to it, is left unsaid.
- **The widely accepted restrictions on global variables and on goto.** Discipline by prohibition: shared state and free transitions are discouraged, where they could have been declared and checked.
- **Monads.** State is threaded through the types of functions, so that it can be handled without ever becoming a domain of its own.
- **Software design patterns.** Recurring arrangements of state, such as a singleton, a list of observers or an injected context, are kept as conventions because the language has no place to declare them.
- **Unconditional garbage collection.** Lifetimes are never declared, so the runtime has to discover them.

The list is not complete.

### What Arspec changes

I believe Arspec can offer a much better resolution of this long-standing problem. A program held as a graph is not bound to one linear reading. The same statements can be shown through as many perspectives as the program needs: one for the state and its contracts, another for the instructions, each a click away from the other. The constraint that forced the two domains into a single text is gone.

So state management can be introduced as an independent, first-class mechanism into the now mostly "functional" world of modern programming. That should make building and analysing many hard cases more natural and more efficient, and easier to reason about for humans and for machines alike.

### What state management means here

1. **No implicit rules.** Today a function is given no knowledge at all of what lies on the stack below it. If a useful piece of data is there, it should be reachable, provided the context the function runs in is known and declared.
2. **Every piece of state has a contract.** Each variable, structure or set of structures states strictly who may own it, in what context it may appear, and what its caller must respect.
3. **Scope is declared, not special-cased.** Global variables are allowed. So are semi-global ones, for example state that exists only while an HTTP server processes the current request. Access to the global handles that represent I/O, or any other potential security risk, can be isolated in the same way.
4. **Parameters are state.** A function's parameters become a solid piece of state, declared independently of the function itself. That state can be copied, modified by several external actors, and kept around after the function has returned control. In OOP terms, every free function and every method is a class of its own, with a single `__call__` method and with the parameters as the members of the instance.

## The design as it stands

This section describes [instruct.ttl](./instruct.ttl) as of October 2026. It is a draft, and the vocabulary is small on purpose: 16 classes, 24 properties, 14 operators, and the little the machine itself provides: two frames, one slot and one function.

The vocabulary has two halves, matching the two domains.

### State: frames and slots

- A **Frame** is a declared piece of state: a named set of slots. It belongs to no function and no module until something says so.
- A **Slot** is one named place in a frame, holding one value. A slot names its frame with `of` and its position with `order`. A variable, a parameter, a result and a field are all slots. What tells them apart is who writes the slot and when, and that is the contract's business, not a kind of slot.

A slot's contract is said with four properties:

| Property | What it states |
|---|---|
| `holds` | What the slot holds: a datatype for a plain value, or a frame for an instance of it. |
| `initially` | What the slot holds when its frame is made. |
| `owns` | Whether the instance it holds is the slot's own: made into it, and gone when the slot's frame goes. Unsaid, the slot holds a reference to an instance some other slot owns. |
| `writer` | Which functions may write the slot. Unsaid, any function in reach of it may. |

A frame's contract is one property, `within`. It names the frame whose instance must stand above every instance of this one, along the chain of owners. The slots of that upper instance are in reach of whatever runs below. This one relation covers three things that are usually separate features:

- a **global** is a slot of a frame that nothing stands above;
- a **request-wide variable** is a slot of the request's frame;
- a **capability** is a frame one must stand within: a frame within the console can speak, and one that is not cannot be made to.

There is no garbage collector. Every instance has exactly one owning slot, and the chain of owners is its lifetime.

### Instructions: functions, blocks and nine kinds of step

- A **Function** takes exactly one frame and runs on an instance of it. It has no parameters and no locals of its own. What it is given, what it works in and what it leaves behind are slots of the frame. It reaches those slots and the slots of the frames up the `within` chain, and nothing else.
- Several functions that take the same frame are what a class with its methods is.
- A **Block** is a list of instructions in `order`: a function's `body`, a branch of an If, the turn of a While.
- An **Instruction** is one transition of state, and it is flat. Every operand is a slot or a constant, never another instruction, so an instruction reads as one row.

| Instruction | Reads as |
|---|---|
| Set | `target := value` |
| Compute | `target := left op right` |
| Make | `target :=` a new instance of `frame` |
| Put | `into.slot := value`, a slot of the instance another slot holds |
| Get | `target := from.slot` |
| Call | run `function` on the instance the slot `on` holds, or on the running instance |
| If | run `then` where `left op right` holds, else `else` |
| While | run `do` for as long as `left op right` holds |
| Return | end the function |

Control flow is structured. There is no jump.

Naming a slot is enough to address it. The slot is either in the running instance or in the one instance of its frame up the context, so there is always exactly one.

### The call

Nothing is passed and nothing is returned. A caller makes the frame, fills it, calls on it and reads what was left there:

```turtle
[ a ins:Make ; ins:target :Main_fact ; ins:frame :Fact ] ,
[ a ins:Put  ; ins:into :Main_fact ; ins:slot :Fact_n ; ins:value 5 ] ,
[ a ins:Call ; ins:function :factorial ; ins:on :Main_fact ] ,
[ a ins:Get  ; ins:target :Main_answer ; ins:from :Main_fact ; ins:slot :Fact_result ]
```

The frame exists before the call and stands after it. Anyone in reach may fill it or read it, before or after, which is requirement 4 of the rationale taken literally. Return carries nothing, because a result is a slot that was written earlier.

### The machine

A **Native** function is one the machine provides. It takes a frame like any function and has no body to read. The draft has one, `say`, which takes the frame `Say` with its single slot `text`. `Say` stands within `Console`, the frame for the terminal, of which the machine makes the one instance.

### How the requirements map

| Requirement | Where the design answers it |
|---|---|
| No implicit rules | `within`: what lies below a function is state it was told about, not a stack it cannot see. In the factorial example each call counts itself in a slot of the frame it stands within. |
| A contract for every piece of state | `holds`, `initially`, `owns`, `writer` on the slot; `within` on the frame. |
| Declared scope, isolated I/O | `within` again, read as a scope and as a capability. |
| Parameters are state | A function takes a frame; the call is Make, Put, Call, Get. |

### Not decided yet

- There is no interpreter. Nothing checks a contract, and nothing runs.
- No entry point is named: which function starts, and on which frame.
- An operand is one slot. It cannot reach through a slot into the instance it holds; that takes a Get first.
- There are no sequences or collections.
- A `writer` is declared, but a reader is not.
- Nothing ends an instance early. It goes only when its owner goes or is made into again.
- What a read of a slot nobody has written yields is not defined.

## Where the ideas come from

The vocabulary was derived from the four requirements above. It was not ported from an existing language. Most of its parts have close relatives all the same. Some were borrowed knowingly while the draft was written. The others are parallels, listed because whoever takes the design further will want to know what was already tried.

### Borrowed

| Part of the design | Source | What was taken, and what differs |
|---|---|---|
| Flat instructions over slots | Three-address code, the usual intermediate form in compilers, and register-based VMs such as Lua's | One operation and at most three operands per instruction. Here it is the form the program is written in, not something a compiler lowers to, because one instruction then fits one row of a perspective. |
| If and While over blocks, no jump | Structured programming, and WebAssembly's structured control flow | A translation to WebAssembly needs no control-flow reconstruction. |
| `owns` | Single ownership in Rust, `unique_ptr` and RAII in C++ | One owner, and the lifetime follows it. Here ownership is declared on the slot in the data model. Nothing like a borrow checker is defined for the references. |
| `within` read as a capability | The object-capability model, as in the E language, and capability-based systems such as WASI | Authority comes only from what is in reach. Here reach is a declared relation between frames, not a reference that gets passed around. |
| A function as a class with one call | Callable objects: `__call__` in Python, `operator()` in C++ | The analogy the rationale itself uses. The frame is the instance, and the function is its only method unless more functions take the same frame. |
| `order` on members | Arspec's own convention for ordered lists | A number on each member, where RDF would offer a linked list. Rows can then be sorted, moved and inserted by the existing perspective machinery. |

### Parallels

| Part of the design | Relative | The resemblance |
|---|---|---|
| A frame that outlives its call | Simula 67, where the class grew out of the Algol block: an object is an activation record that stays after its body has run | The same step, taken for every function and not only for classes. |
| Make, Put, Call, Get | Function blocks in IEC 61131-3, the PLC languages | An instance with inputs, outputs and retained internals. The caller sets the inputs, calls, and reads the outputs off the instance. |
| A frame as a first-class object | Contexts in Smalltalk, heap-allocated frames in Scheme, the frames of generators and coroutines in Python and C++20 | The activation record as a value that can be held, inspected and resumed. Those languages make it available. Here it is the only form there is. |
| `within` as a chain of contexts | The static chain of nested procedures in Algol and Pascal | Reaching the variables of an enclosing activation. Here the chain is declared between pieces of state, where there it follows the nesting of the code. |
| `within` as request-wide state | Dynamic scoping in Lisp, `context.Context` in Go, React context, scoped lifetimes in dependency-injection containers | State that is in reach for everything running under some activation, without being passed by hand. |
| `writer`, and who fills a slot when | Parameter modes in Ada: `in`, `out`, `in out` | A declaration of who writes a place, kept on the place. |
| State declared apart from the code that changes it | "Out of the Tar Pit" by Moseley and Marks; TLA+, where a system is its variables and its actions; the Elm architecture and Redux; entity-component-system designs in game engines | Each separates what the state is from what transitions it. Most of them stop at one global state. Frames and `within` are an attempt at the same separation with structure and lifetimes. |
| A program that is not text | Projectional editors such as JetBrains MPS, the Smalltalk image, Unison's code database | The program is stored as structure, and what the programmer sees is a projection of it. This is the premise of the rationale, and Arspec's perspectives are the projection. |

## Companion files

- [algorithms.ttl](./algorithms.ttl) holds three small programs written in the vocabulary: Euclid's gcd as a loop over two slots, a recursive factorial in which each call makes the frame of the next, and a main that runs the factorial and says the answer.
- [dev.arspec](./dev.arspec) is the topic that opens both files, with four perspectives built from Arspec's existing machinery: Frames, Functions, Block and Vocabulary.
