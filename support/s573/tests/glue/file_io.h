#pragma once
int FileCreatePath(const char *dir);
int FileSave(const char *name, void *pBuffer, int size);
int FileLoad(const char *name, void *pBuffer, int size);
