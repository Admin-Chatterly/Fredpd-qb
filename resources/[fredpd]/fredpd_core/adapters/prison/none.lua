-- SPDX-License-Identifier: GPL-3.0-only
-- prison adapter "none": no integration installed; every call is the prison no-op from adapters/base.lua.
return require('adapters.base').define({ kind = 'prison', name = 'none' })
