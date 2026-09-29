-- SPDX-License-Identifier: GPL-3.0-only
-- garage adapter "none": no integration installed; every call is the garage no-op from adapters/base.lua.
return require('adapters.base').define({ kind = 'garage', name = 'none' })
