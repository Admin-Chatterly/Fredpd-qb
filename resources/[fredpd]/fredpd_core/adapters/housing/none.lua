-- SPDX-License-Identifier: GPL-3.0-only
-- housing adapter "none": no integration installed; every call is the housing no-op from adapters/base.lua.
return require('adapters.base').define({ kind = 'housing', name = 'none' })
