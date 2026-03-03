# Contributing to QuickFlip

Thank you for your interest in improving QuickFlip! This document outlines the
guidelines and process for contributing to the project.

---

## 📜 License Agreement

By submitting a contribution (pull request) to this repository, you agree to
the terms outlined in [LICENSE.md](LICENSE.md). In particular:

- You grant the project author a **perpetual, irrevocable, royalty-free
  license** to use, modify, and distribute your contribution as part of the
  Software.
- You confirm that your contribution is your **original work** and does not
  infringe on any third-party intellectual property rights.
- Your contribution will be governed by the same restrictive license as the
  rest of the project.

---

## 🛠️ How to Contribute

### 1. Fork and Clone

1. Fork this repository to your own GitHub account.
2. Clone your fork locally:
   ```bash
   git clone https://github.com/YOUR-USERNAME/AH-Scalper.git
   ```
3. Create a new branch for your changes:
   ```bash
   git checkout -b feature/your-feature-name
   ```

### 2. Make Your Changes

- Follow the **coding conventions** described below.
- Test your changes in-game using `/reload` to verify they work correctly.
- Ensure all `.lua` files pass syntax checking:
  ```bash
  luac5.1 -p *.lua
  ```

### 3. Submit a Pull Request

1. Push your branch to your fork.
2. Open a pull request against the `main` branch of this repository.
3. Provide a clear description of what your changes do and why they are needed.
4. Reference any related issues (e.g. "Fixes #42").

---

## 📏 Coding Conventions

### Lua Style

| Element                | Convention                                              |
|------------------------|---------------------------------------------------------|
| Local variables        | `camelCase` (e.g. `maxBuyPrice`, `isScanning`)          |
| Namespace functions    | `ns.PascalCase` (e.g. `ns.StartScan`, `ns.FormatMoney`) |
| Private/internal names | Prefix with `_` (e.g. `_tabCreated`, `_listsPanel`)    |
| Constants              | `SCREAMING_SNAKE_CASE` (e.g. `STATE_IDLE`, `SOUND_DEAL`) |

### Comments

- Use `--` for inline comments explaining individual instructions or logic.
- Use `---` for documentation comments above functions with `@param` and
  `@return` tags.
- Use block comment headers (`-----------...`) to separate major sections
  within a file.
- **Every function** must have a documentation block explaining its purpose,
  parameters, and return values.
- **Every non-trivial instruction set** should have an inline comment
  explaining what it does and why.

### Example

```lua
---------------------------------------------------------------------------
-- MyFunction — brief description of what it does
---------------------------------------------------------------------------
-- Detailed explanation of the function's purpose, edge cases, and any
-- important implementation details the reader should know.
--
-- @param  paramName (type)  Description of the parameter
-- @return (type)  Description of the return value
---------------------------------------------------------------------------
function ns.MyFunction(paramName)
    -- Validate input before processing
    if not paramName then return nil end

    -- Calculate the result using the formula: result = input * multiplier
    local result = paramName * ns.MULTIPLIER

    return result  -- Return the computed value
end
```

### File Structure

Every `.lua` file must follow this structure:

1. **File header block** — file name, purpose, and overview of contents.
2. **Namespace declaration** — `local ADDON_NAME, ns = ...` with a reference
   to `Core.lua` for the full namespace pattern explanation.
3. **Constants/locals** — module-level constants and upvalues.
4. **Functions** — each with a documentation block, separated by section
   headers.

### Naming Frames

All WoW frames created by the addon use the `QuickFlip` prefix:
- `QuickFlipPanel`, `QuickFlipBuyBtn`, `QuickFlipSellFrame`, etc.

---

## 🧪 Testing

There is no automated test suite — all testing is performed in-game.

### Before Submitting

1. **Syntax check** all Lua files:
   ```bash
   luac5.1 -p Config.lua Utils.lua ListManager.lua Scanner.lua Buyer.lua Seller.lua UI.lua Core.lua
   ```
2. **In-game verification**:
   - `/reload` to load changes
   - Open the Auction House and verify all three tabs appear (Flip, Quick Sell, Lists)
   - Test the specific feature you changed
   - Verify settings persist across `/reload`
3. **Remove debug prints** — do not leave `print()` or debug output in your
   final submission.

---

## 🐛 Reporting Issues

When opening an issue, please include:

1. **WoW version** (e.g. 12.0.5)
2. **Addon version** (shown in chat on login or via `/qf`)
3. **Steps to reproduce** the problem
4. **Expected behaviour** vs. **actual behaviour**
5. **Lua error text** if applicable (enable Lua errors via
   Interface → Display → Show Lua Errors)

---

## 🚫 What We Will Not Accept

- Changes that add external addon dependencies (QuickFlip must remain standalone)
- Code copied from other addons or projects without explicit MIT/Public Domain
  licensing
- Features that automate gameplay beyond what WoW's API permits (no botting,
  no bypassing hardware event requirements)
- Modifications to bundled libraries (LibStub, LibAHTab) — report upstream

---

## 💬 Questions?

Open a GitHub issue tagged with the **question** label. We are happy to help
you get started with contributing.
