#pragma once
#include <stdint.h>
#include <sys/types.h>
/* the members of Main's fileTYPE (file_io.h) the glue uses */
struct fileTYPE
{
	int opened() { return filp != 0; }
	void           *filp = 0;
	__off64_t       size = 0;
	__off64_t       offset = 0;
	char            name[261] = {};
};
int FileCreatePath(const char *dir);
int FileSave(const char *name, void *pBuffer, int size);
int FileLoad(const char *name, void *pBuffer, int size);
int FileSeek(fileTYPE *file, __off64_t offset, int origin);
int FileReadAdv(fileTYPE *file, void *pBuffer, int length, int failres = 0);
int FileWriteAdv(fileTYPE *file, void *pBuffer, int length, int failres = 0);
