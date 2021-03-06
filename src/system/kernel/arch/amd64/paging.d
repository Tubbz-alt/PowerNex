module arch.amd64.paging;

import stl.vmm.paging;

import arch.paging;
import stl.address;
import stl.register;
import stl.trait;
import stl.vmm.vmm;
import stl.io.log;

/*
	Recursive mapping info is from http://os.phil-opp.com/modifying-page-tables.html
*/

private const _pageSize = 0x1000; //TODO: Is needed?

/// Page table level
@safe struct PTLevel(NextLevel) {
	@safe struct TableEntry {
		private ulong _data;

		this(TableEntry other) {
			_data = other.data;
		}

		/// If the map is active
		@property bool present() const {
			return cast(bool)((_data >> 0x0UL) & 0x1UL);
		}
		/// ditto
		@property void present(bool val) {
			_data = (_data & ~(0x1UL << 0x0UL)) | ((val & 0x1UL) << 0x0UL);
		}

		// If the page is R/W instead of R/O
		@property bool readWrite() const {
			return cast(bool)((_data >> 0x1UL) & 0x1UL);
		}
		/// ditto
		@property void readWrite(bool val) {
			_data = (_data & ~(0x1UL << 0x1UL)) | ((val & 0x1UL) << 0x1UL);
		}

		/// If userspace can access this page
		@property bool user() const {
			return cast(bool)((_data >> 0x2UL) & 0x1UL);
		}
		/// ditto
		@property void user(bool val) {
			_data = (_data & ~(0x1UL << 0x2UL)) | ((val & 0x1UL) << 0x2UL);
		}

		/// If the map should bypass the cache and write directly to memory
		@property bool writeThrough() const {
			return cast(bool)((_data >> 0x3UL) & 0x1UL);
		}
		/// ditto
		@property void writeThrough(bool val) {
			_data = (_data & ~(0x1UL << 0x3UL)) | ((val & 0x1UL) << 0x3UL);
		}

		/// If the map should bypass the read cache and read directly from memory
		@property bool cacheDisable() const {
			return cast(bool)((_data >> 0x4UL) & 0x1UL);
		}
		/// ditto
		@property void cacheDisable(bool val) {
			_data = (_data & ~(0x1UL << 0x4UL)) | ((val & 0x1UL) << 0x4UL);
		}

		/// Is set when page has been accessed
		@property bool accessed() const {
			return cast(bool)((_data >> 0x5UL) & 0x1UL);
		}
		/// ditto
		@property void accessed(bool val) {
			_data = (_data & ~(0x1UL << 0x5UL)) | ((val & 0x1UL) << 0x5UL);
		}

		/// Is set when page has been written to
		/// NOTE: Only valid if hugeMap is 1, else this value should be zero
		@property bool dirty() const {
			return cast(bool)((_data >> 0x6UL) & 0x1UL);
		}
		/// ditto
		@property void dirty(bool val) {
			_data = (_data & ~(0x1UL << 0x6UL)) | ((val & 0x1UL) << 0x6UL);
		}

		/**
			Maps bigger pages
			Note:
				PML4: Must be zero,
				PDP: Works like a Page, but maps 1GiB
				PD: Works like a Page, but maps 4MiB
				Page: Not valid function, pat overrides this property

			See_Also:
				hugeMap, pat
		*/
		@property bool hugeMap() const {
			return cast(bool)((_data >> 0x7UL) & 0x1UL);
		}
		/// ditto
		@property void hugeMap(bool val) {
			_data = (_data & ~(0x1UL << 0x7UL)) | ((val & 0x1UL) << 0x7UL);
		}

		/**
			Not implemented, Will probably be used in the future

			Docs:
				http://developer.amd.com/wordpress/media/2012/10/24593_APM_v21.pdf p.199

			See_Also:
				hugeMap
		*/
		@disable @property bool pat() const {
			return cast(bool)((_data >> 0x7UL) & 0x1UL);
		}
		/// ditto
		@disable @property void pat(bool val) {
			_data = (_data & ~(0x1UL << 0x7UL)) | ((val & 0x1UL) << 0x7UL);
		}

		/// Is not cleared from the cache on a PML4 switch
		@property bool global() const {
			return cast(bool)((_data >> 0x8UL) & 0x1UL);
		}
		/// ditto
		@property void global(bool val) {
			_data = (_data & ~(0x1UL << 0x8UL)) | ((val & 0x1UL) << 0x8UL);
		}

		/// For future PowerNex usage (3bits)
		@property ubyte osSpecific() const {
			return cast(ubyte)((_data >> 0x9UL) & 0x7UL);
		}
		/// ditto
		@property void osSpecific(ubyte val) {
			_data = (_data & ~(0x7UL << 0x9UL)) | ((val & 0x7UL) << 0x9UL);
		}

		/// The address to the next level in the page tables, or the final map address
		@property ulong data() const {
			return cast(ulong)((_data >> 0xCUL) & 0xFFFFFFFFFFUL);
		}
		/// ditto
		@property void data(ulong val) {
			_data = (_data & ~(0xFFFFFFFFFFUL << 0xCUL)) | ((val & 0xFFFFFFFFFFUL) << 0xCUL);
		}

		/// For future PowerNex usage (10bits)
		@property ushort osSpecific2() const {
			return cast(ushort)((_data >> 0x34UL) & 0x7FFUL);
		}
		/// ditto
		@property void osSpecific2(ushort val) {
			_data = (_data & ~(0x7FFUL << 0x34UL)) | ((val & 0x7FFUL) << 0x34UL);
		}

		/// Forbids execution in the map
		@property bool noExecute() const {
			return cast(bool)((_data >> 0x3FUL) & 0x1UL);
		}
		/// ditto
		@property void noExecute(bool val) {
			_data = (_data & ~(0x1UL << 0x3FUL)) | ((val & 0x1UL) << 0x3FUL);
		}

		@property PhysAddress address() const {
			return PhysAddress(data << 12);
		}

		@property PhysAddress address(PhysAddress addr) {
			data = addr.num >> 12;
			return addr;
		}

		static if (!is(NextLevel == Page))
			@property NextLevel* getPageTable() {
				ushort id = cast(ushort)((VirtAddress(&this) & 0xFFF).num / ulong.sizeof);
				return (((VirtAddress(&this) & ~0xFFF) << 9) | (id << 12)).ptr!NextLevel;
			}

		@property VMPageFlags vmFlags() const {
			VMPageFlags flags;
			if (!present)
				return VMPageFlags.none;

			flags |= VMPageFlags.present;
			if (readWrite)
				flags |= VMPageFlags.writable;
			if (user)
				flags |= VMPageFlags.user;
			if (!noExecute) //NOTE '!'
				flags |= VMPageFlags.execute;
			return flags;
		}

		@property void vmFlags(VMPageFlags flags) {
			present = !!(flags & flags.present);
			readWrite = !!(flags & flags.writable);
			user = !!(flags & flags.user);
			noExecute = !(flags & flags.execute); //NOTE! Just one '!'
		}
	}

	static assert(TableEntry.sizeof == ulong.sizeof);

	TableEntry[512] entries;
	static if (!is(NextLevel == Page))
		@property NextLevel* getPageTable(ushort id) {
			assert(id < 512);
			return ((VirtAddress(&this) << 9) | (id << 12)).ptr!NextLevel;
		}
}

alias Page = PhysAddress;
alias PML1 = PTLevel!Page;
alias PML2 = PTLevel!PML1;
alias PML3 = PTLevel!PML2;
alias PML4 = PTLevel!PML3;

/**
	* Each VMObject will be have a 4GiB zone, aka one PML3 each.
	*
	* Note:
	*  Only the lowest 9 bits will be used, because each PML4 only contains 512 entries.
	*/
alias HWZoneIdentifier = ushort;

private extern (C) void cpuFlushPage(ulong addr) @safe;
private extern (C) void cpuInstallCR3(PhysAddress addr) @safe;

@safe struct Paging {
public:
	@disable this();
	this(PhysAddress pml4Address, bool ownsPML4) {
		_addr = pml4Address;
		_ownsPML4 = ownsPML4;
	}

	this(ref Paging other) {
		assert(0, "copy");
	}

	this(this) {
		_ownsPML4 = false;
	}

	~this() {
		if (_ownsPML4)
			freePage(_addr);
	}

	void dump() {
		import stl.io.log;

		Log.verbose();
		Log.verbose();
		Log.verbose("PML4 (", _addr, ")");
		foreach (ushort pml3Idx, PML4.TableEntry pml3; _getPML4().entries) {
			if (!pml3.address)
				continue;
			Log.verbose('[', pml3Idx, ']', " PML3 (", pml3.address, ")");
			if (pml3Idx == 509)
				continue;
			foreach (ushort pml2Idx, PML3.TableEntry pml2; _getPML3(pml3Idx).entries) {
				if (!pml2.address)
					continue;
				Log.verbose('[', pml3Idx, ']', '[', pml2Idx, ']', " PML2 (", pml2.address, ")");
			}
		}
		Log.verbose();
		Log.verbose();

		Log.debug_();
		Log.debug_();
		PML1* special = _getSpecial();
		foreach (idx, const ref PML1.TableEntry entry; special.entries) {
			if (!entry.present)
				continue;
			Log.debug_("[510][0][0][", idx, "]");
		}
		Log.debug_();
		Log.debug_();
	}

	static Paging newCleanPaging() {
		import stl.vmm.frameallocator;

		PhysAddress pAddr = FrameAllocator.alloc();
		PhysAddress pml3_0 = FrameAllocator.alloc();
		PhysAddress pml2_0_0 = FrameAllocator.alloc();
		PhysAddress pml1_0_0_0 = FrameAllocator.alloc();
		PhysAddress page_0_0_0_0 = FrameAllocator.alloc();
		PhysAddress page_0_0_0_184 = FrameAllocator.alloc();
		PhysAddress pml3_510 = FrameAllocator.alloc();
		PhysAddress pml2_510_0 = FrameAllocator.alloc();
		PhysAddress pml1_510_0_0 = FrameAllocator.alloc();

		enum kernelFlags = 1 /* present */  + 2 /* readwrite*/ ;
		enum userFlags = kernelFlags + 4 /* user */ ;

		{
			VirtAddress vAddr = getKernelPaging().mapSpecialAddress(pAddr, 0x1000, true, true);
			ulong[] pml4 = vAddr.array!ulong(0x1000 / ulong.sizeof);
			//pml4[0] = getKernelPaging()._getPML4().entries[0]._data;
			pml4[0] = pml3_0.num!ulong + userFlags;
			pml4[500] = getKernelPaging()._getPML4().entries[500]._data;
			pml4[509] = pAddr.num!ulong + kernelFlags;
			pml4[510] = pml3_510.num!ulong + kernelFlags;
			//pml4[510] = getKernelPaging()._getPML4().entries[510]._data;
			pml4[511] = getKernelPaging()._getPML4().entries[511]._data;
			getKernelPaging().unmapSpecialAddress(vAddr, 0x1000);
		}

		{
			VirtAddress vAddr = getKernelPaging().mapSpecialAddress(pml3_0, 0x1000, true, true);
			ulong[] pml3 = vAddr.array!ulong(0x1000 / ulong.sizeof);
			pml3[0] = pml2_0_0.num!ulong + userFlags;
			//pml3[0] = getKernelPaging()._getPML3(0).entries[0]._data;
			getKernelPaging().unmapSpecialAddress(vAddr, 0x1000);
		}
		{
			VirtAddress vAddr = getKernelPaging().mapSpecialAddress(pml2_0_0, 0x1000, true, true);
			ulong[] pml2 = vAddr.array!ulong(0x1000 / ulong.sizeof);
			pml2[0] = pml1_0_0_0.num!ulong + userFlags;
			pml2[0] = getKernelPaging()._getPML2(0, 0).entries[0]._data;
			getKernelPaging().unmapSpecialAddress(vAddr, 0x1000);
		}
		{
			VirtAddress vAddr = getKernelPaging().mapSpecialAddress(pml1_0_0_0, 0x1000, true, true);
			ulong[] pml1 = vAddr.array!ulong(0x1000 / ulong.sizeof);
			//pml1[0] = page_0_0_0_0.num!ulong + userFlags;
			//pml1[page_0_0_0_184] = page_0_0_0_184.num!ulong + userFlags;
			pml1[0] = getKernelPaging()._getPML1(0, 0, 0).entries[0]._data;
			pml1[1] = getKernelPaging()._getPML1(0, 0, 0).entries[1]._data;
			getKernelPaging().unmapSpecialAddress(vAddr, 0x1000);
		} /*
		{
			VirtAddress vAddr = getKernelPaging().mapSpecialAddress(page_0_0_0_0, 0x1000, true, true);
			ulong[] page = vAddr.array!ulong(0x1000 / ulong.sizeof);
			foreach (i; 1 .. 512)
				page[i] = i * 0x1000 + 3;
			getKernelPaging().unmapSpecialAddress(vAddr, 0x1000);
		}
		{
			VirtAddress vAddr = getKernelPaging().mapSpecialAddress(page_0_0_0_184, 0x1000, true, true);
			ulong[] page = vAddr.array!ulong(0x1000 / ulong.sizeof);
			foreach (i; 0 .. 512)
				page[i] = 0xB8000 + i * 0x1000 + 3;
			getKernelPaging().unmapSpecialAddress(vAddr, 0x1000);
		}*/

		{
			VirtAddress vAddr = getKernelPaging().mapSpecialAddress(pml3_510, 0x1000, true, true);
			ulong[] pml3 = vAddr.array!ulong(0x1000 / ulong.sizeof);
			pml3[0] = pml2_510_0.num!ulong + kernelFlags;
			pml3[1] = getKernelPaging()._getPML3(510).entries[1]._data;
			getKernelPaging().unmapSpecialAddress(vAddr, 0x1000);
		}
		{
			VirtAddress vAddr = getKernelPaging().mapSpecialAddress(pml2_510_0, 0x1000, true, true);
			ulong[] pml2 = vAddr.array!ulong(0x1000 / ulong.sizeof);
			pml2[0] = pml1_510_0_0.num!ulong + kernelFlags;
			pml2[1] = getKernelPaging()._getPML2(510, 0).entries[1]._data;
			foreach (i; 2 .. 17)
				pml2[i] = getKernelPaging()._getPML2(510, 0).entries[i]._data;
			getKernelPaging().unmapSpecialAddress(vAddr, 0x1000);
		}
		{
			VirtAddress vAddr = getKernelPaging().mapSpecialAddress(pml1_510_0_0, 0x1000, true, true);
			getKernelPaging().unmapSpecialAddress(vAddr, 0x1000);
		}

		// Add the possible to get and add (_getPML{4,3,2,1}) WITHOUT the PML4 being active (CR3).

		return Paging(pAddr, true);
	}

	///
	VirtAddress mapSpecialAddress(PhysAddress pAddr, size_t size, bool readWrite = false, bool clear = false) {
		const PhysAddress pa = pAddr & ~0xFFF;
		const size_t offset = pAddr.num & 0xFFF;

		return mapSpecial(pa, size + offset, VMPageFlags.present | (readWrite ? VMPageFlags.writable : VMPageFlags.none), clear) + offset;
	}

	///
	void unmapSpecialAddress(ref VirtAddress vAddr, size_t size) {
		vAddr &= ~0xFFF;
		const size_t pagesNeeded = ((size + 0xFFF) & ~0xFFF) / 0x1000;

		debug (Paging)
			Log.info("Unmapping special [", vAddr, " - ", vAddr + pagesNeeded * 0x1000 - 1, "]");
		foreach (i; 0 .. pagesNeeded) {
			unmap(vAddr, false);
			vAddr += 0x1000;
		}
		vAddr.addr = 0;
	}

	VirtAddress mapSpecial(PhysAddress pAddr, size_t size, VMPageFlags flags = VMPageFlags.present, bool clear = false) {
		import stl.io.log : Log;

		const size_t pagesNeeded = ((size + 0xFFF) & ~0xFFF) / 0x1000;

		const ulong specialID = 510; // XXX: Find this from somewhere else
		PML1* special = _getSpecial();

		size_t freePage = size_t.max;
		size_t amountFree;
		foreach (idx, const ref PML1.TableEntry entry; special.entries) {
			if (!entry.present) {
				if (!amountFree)
					freePage = idx;
				amountFree++;
				if (pagesNeeded == amountFree)
					break;
			} else
				amountFree = 0;
		}

		if (freePage == size_t.max || pagesNeeded != amountFree)
			Log.fatal("Special PML1 is full! freePage: ", freePage, "\t", pagesNeeded, " != ", amountFree);

		VirtAddress vAddr = makeAddress(specialID, 0, 0, freePage);
		debug (Paging)
			Log.info("Mapping special [", vAddr, " - ", vAddr + pagesNeeded * 0x1000 - 1, "]");
		foreach (i; 0 .. pagesNeeded) {
			PML1.TableEntry* entry = &special.entries[freePage + i];

			entry.address = pAddr + i * 0x1000;
			entry.vmFlags = flags | (clear ? VMPageFlags.writable : VMPageFlags.none);
			_flush(vAddr);

			if (clear) {
				vAddr.memset(0, _pageSize);
				entry.readWrite = !!(flags & flags.writable);
				_flush(vAddr);
			}
		}
		return vAddr;
	}

	bool mapAddress(VirtAddress vAddr, PhysAddress pAddr, VMPageFlags flags, bool clear = false) {
		PML1.TableEntry* entry = _getTableEntry(vAddr);
		if (!entry) {
			Log.error("Table entry not found: ", vAddr);
			return false;
		}

		if (entry.present) {
			Log.error("Address is already mapped: ", vAddr, " to: ", entry.address);
			return false;
		}

		entry.address = pAddr ? pAddr : getNextFreePage();
		entry.vmFlags(flags | (clear ? VMPageFlags.writable : VMPageFlags.none));
		_flush(vAddr);

		if (clear) {
			memset(vAddr.ptr, 0, _pageSize);
			entry.readWrite = !!(flags & flags.writable);
			_flush(vAddr);
		}
		return true;
	}

	/**
		* Changes a mappings properties.
		*/
	bool remap(VirtAddress vAddr, PhysAddress pAddr, VMPageFlags flags) {
		PML1.TableEntry* entry = _getTableEntry(vAddr);
		if (!entry)
			return false;

		entry.address = pAddr;
		entry.vmFlags(flags);
		_flush(vAddr);
		return true;
	}

	bool unmap(VirtAddress vAddr, bool freePage = false) {
		PML1.TableEntry* entry = _getTableEntry(vAddr);
		if (!entry)
			return false;

		if (freePage) {
			import stl.vmm.frameallocator : FrameAllocator;

			FrameAllocator.free(entry.address);
		}

		entry.address = PhysAddress();
		entry.vmFlags(VMPageFlags.none);

		_flush(vAddr);
		return true;
	}

	PhysAddress clonePage(PhysAddress page) {
		const ulong specialID = 510;
		//TODO: This probably needs fixing for the multicore update!
		enum Position : ushort {
			from = 0,
			to = 1
		}

		//TODO: Maybe check permissions if it is allowed to read `page`

		PML1.TableEntry* from = &_getSpecial().entries[Position.from];
		PML1.TableEntry* to = &_getSpecial().entries[Position.to];
		VirtAddress vFrom = makeAddress(specialID, 0, 0, Position.from);
		VirtAddress vTo = makeAddress(specialID, 0, 0, Position.to);

		from.address = page;
		from.present = true;

		to.address = getNextFreePage();
		to.readWrite = true;
		to.present = true;

		_flush(vFrom);
		_flush(vTo);

		memcpy(vTo.ptr, vFrom.ptr, _pageSize);

		from.present = false;
		to.present = false;
		_flush(vFrom);
		_flush(vTo);
		return to.address;
	}

	PhysAddress getNextFreePage() const {
		import stl.vmm.frameallocator : FrameAllocator;

		return FrameAllocator.alloc();
	}

	void freePage(PhysAddress page) {
		import stl.vmm.frameallocator : FrameAllocator;

		return FrameAllocator.free(page);
	}

	void bind() {
		cpuInstallCR3(_addr);
	}

	PhysAddress getPhysAddress(VirtAddress vAddr) {
		PML1.TableEntry* page = _getTableEntry(vAddr, false);
		if (page)
			return page.address();
		return PhysAddress();
	}

	VMPageFlags getPageFlags(VirtAddress vAddr) {
		PML1.TableEntry* page = _getTableEntry(vAddr, false);
		if (page)
			return page.vmFlags();
		return VMPageFlags();
	}

	@property bool isValid(VirtAddress vAddr) {
		return vAddr && !!_getTableEntry(vAddr, false);
	}

	@property PhysAddress tableAddress() {
		return _addr;
	}

private:
	PhysAddress _addr;
	bool _ownsPML4;

	void _flush(VirtAddress vAddr) {
		cpuFlushPage(vAddr.num);
	}

	PML4* _getPML4() nothrow {
		const ulong fractalID = 509;
		return makeAddress(fractalID, fractalID, fractalID, fractalID).ptr!PML4;
	}

	PML3* _getPML3(ushort pml4) nothrow {
		const ulong fractalID = 509;
		return makeAddress(fractalID, fractalID, fractalID, pml4).ptr!PML3;
	}

	PML2* _getPML2(ushort pml4, ushort pml3) nothrow {
		const ulong fractalID = 509;
		return makeAddress(fractalID, fractalID, pml4, pml3).ptr!PML2;
	}

	PML1* _getPML1(ushort pml4, ushort pml3, ushort pml2) nothrow {
		const ulong fractalID = 509;
		return makeAddress(fractalID, pml4, pml3, pml2).ptr!PML1;
	}

	PML1* _getSpecial() nothrow {
		const ulong specialID = 510;
		return _getPML1(specialID, 0, 0);
	}

	/// Will allocate PML{3,2,1} if missing
	PML1.TableEntry* _getTableEntry(VirtAddress vAddr, bool allocateWay = true) {
		const ulong virtAddr = vAddr.num;
		const ushort pml4Idx = (virtAddr >> 39) & 0x1FF;
		const ushort pml3Idx = (virtAddr >> 30) & 0x1FF;
		const ushort pml2Idx = (virtAddr >> 21) & 0x1FF;
		const ushort pml1Idx = (virtAddr >> 12) & 0x1FF;
		const bool isUserZone = !((pml4Idx >> 8) & 0x1);

		PML4* pml4 = _getPML4();

		// This address can be unallocated, the 'if' will allocate it in that case
		PML3* pml3 = _getPML3(pml4Idx);
		{
			PML4.TableEntry* pml4Entry = &pml4.entries[pml4Idx];

			if (!pml4Entry.present)
				if (allocateWay)
					_allocateTable(pml4Entry, pml3.VirtAddress, isUserZone); //TODO: Is it allowed to allocate a PML4 entry? Permissions!
				else
					return null;
		}

		PML2* pml2 = _getPML2(pml4Idx, pml3Idx);
		{
			PML3.TableEntry* pml3Entry = &pml3.entries[pml3Idx];
			if (!pml3Entry.present)
				if (allocateWay)
					_allocateTable(pml3Entry, pml2.VirtAddress, isUserZone);
				else
					return null;

		}

		PML1* pml1 = _getPML1(pml4Idx, pml3Idx, pml2Idx);
		{
			PML2.TableEntry* pml2Entry = &pml2.entries[pml2Idx];
			if (!pml2Entry.present)
				if (allocateWay)
					_allocateTable(pml2Entry, pml1.VirtAddress, isUserZone);
				else
					return null;
		}

		return &pml1.entries[pml1Idx];
	}

	/**
		Allocate a new empty page.
		Params:
			entry = The entry that should be allocated.
			vAddr = The address the entry will have in ram.
			isUserZone = If the user should have access to this.
	*/
	void _allocateTable(T)(PTLevel!(T).TableEntry* entry, VirtAddress vAddr, bool isUserZone) if (!is(T == Page)) {
		entry.present = true;
		entry.address = getNextFreePage();
		entry.readWrite = true;
		entry.user = isUserZone;
		_flush(vAddr);
		memset(vAddr.ptr, 0, _pageSize);
	}
}

private extern (C) ulong cpuRetCR3() @safe nothrow;

extern (C) void onPageFault(Registers* regs) @trusted {
	import stl.io.vga;
	import stl.io.log;
	import stl.arch.amd64.cpu : getCoreID;
	import stl.text : HexInt;

	size_t id = getCoreID();

	Paging paging = Paging(cpuRetCR3.PhysAddress, false);

	with (regs) {
		import task.thread : PageFaultStatus;

		PageFaultStatus pfs;
		{
			import task.scheduler;
			import task.thread;

			VMThread* thread = Scheduler.getCurrentThread();
			if (thread) {
				pfs = thread.process.onPageFault(thread, cr2, !!(errorCode.num & 1), !!(errorCode.num & 2), !!(errorCode.num & 4));
				if (pfs == PageFaultStatus.success)
					return;
			}
		}

		const ulong virtAddr = cr2.num;
		const ushort pml4Idx = (virtAddr >> 39) & 0x1FF;
		const ushort pml3Idx = (virtAddr >> 30) & 0x1FF;
		const ushort pml2Idx = (virtAddr >> 21) & 0x1FF;
		const ushort pml1Idx = (virtAddr >> 12) & 0x1FF;

		PML4* pml4 = paging._getPML4();
		PML3* pml3;
		PML2* pml2;
		PML1* pml1;

		VMPageFlags pml3Flags;
		VMPageFlags pml2Flags;
		VMPageFlags pml1Flags;
		VMPageFlags pageFlags;

		{
			auto pml4Entry = &pml4.entries[pml4Idx];
			if (pml4Entry.present) {
				pml3 = paging._getPML3(pml4Idx);
				pml3Flags = pml4Entry.vmFlags;
			}
		}

		if (pml3) {
			auto pml3Entry = &pml3.entries[pml3Idx];
			if (pml3Entry.present) {
				pml2 = paging._getPML2(pml4Idx, pml3Idx);
				pml2Flags = pml3Entry.vmFlags;
			}
		}

		if (pml2) {
			auto pml2Entry = &pml2.entries[pml2Idx];
			if (pml2Entry.present) {
				pml1 = paging._getPML1(pml4Idx, pml3Idx, pml2Idx);
				pml1Flags = pml2Entry.vmFlags;
			}
		}

		if (pml1) {
			auto pml1Entry = &pml1.entries[pml1Idx];
			if (pml1Entry.present)
				pageFlags = pml1Entry.vmFlags;
		}

		ulong cr3 = cpuRetCR3();

		import stl.arch.amd64.msr;

		auto fs = MSR.fs();
		auto gs = MSR.gs();
		auto gsKernel = MSR.gsKernel();

		//dfmt off
		Log.error("===> PAGE FAULT (CPU ", id, ")", "\n",
			"IRQ = ", intNumber, " | RIP = ", rip, "\n",
			"RAX = ", rax, " | RBX = ", rbx, "\n",
			"RCX = ", rcx, " | RDX = ", rdx, "\n",
			"RDI = ", rdi, " | RSI = ", rsi, "\n",
			"RSP = ", rsp, " | RBP = ", rbp, "\n",
			" R8 = ", r8,  " |  R9 = ", r9, "\n",
			"R10 = ", r10, " | R11 = ", r11, "\n",
			"R12 = ", r12, " | R13 = ", r13, "\n",
			"R14 = ", r14, " | R15 = ", r15, "\n",
			" CS = ", cs,  " |  SS = ", ss, "\n",
			"CR0 = ", cr0, " | CR2 = ", cr2, "\n",
			"CR3 = ", cr3, " | CR4 = ", cr4, "\n",
			" FS = ", fs,  "\n",
			" GS = ", gs,  " | gsK = ", gsKernel, "\n",
			"Flags = ", flags.num.HexInt, "\n",
			"Errorcode: ", errorCode, " (",
				(errorCode & (1 << 0) ? " Present" : " NotPresent"),
				(errorCode & (1 << 1) ? " Write" : " Read"),
				(errorCode & (1 << 2) ? " UserMode" : " KernelMode"),
				(errorCode & (1 << 3) ? " ReservedWrite" : ""),
				(errorCode & (1 << 4) ? " InstructionFetch" : ""),
			" )", "\n",
			"PDP Mode: ",
				(pml3Flags & VMPageFlags.present) ? "R" : "",
				(pml3Flags & VMPageFlags.writable) ? "W" : "",
				(pml3Flags & VMPageFlags.execute) ? "X" : "",
				(pml3Flags & VMPageFlags.user) ? "-User" : "", "\n",
			"PD Mode: ",
				(pml2Flags & VMPageFlags.present) ? "R" : "",
				(pml2Flags & VMPageFlags.writable) ? "W" : "",
				(pml2Flags & VMPageFlags.execute) ? "X" : "",
				(pml2Flags & VMPageFlags.user) ? "-User" : "", "\n",
			"PT Mode: ",
				(pml1Flags & VMPageFlags.present) ? "R" : "",
				(pml1Flags & VMPageFlags.writable) ? "W" : "",
				(pml1Flags & VMPageFlags.execute) ? "X" : "",
				(pml1Flags & VMPageFlags.user) ? "-User" : "", "\n",
			"Page Mode: ",
				(pageFlags & VMPageFlags.present) ? "R" : "",
				(pageFlags & VMPageFlags.writable) ? "W" : "",
				(pageFlags & VMPageFlags.execute) ? "X" : "",
				(pageFlags & VMPageFlags.user) ? "-User" : "");
		//dfmt on

		Log.fatal("PageFaultStatus: ", pfs);
	}
}
