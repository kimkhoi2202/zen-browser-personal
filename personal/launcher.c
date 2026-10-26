/* MPL-2.0. Starts the released engine with this channel's own app data/profile. */
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#ifndef PERSONAL_CHANNEL
#error PERSONAL_CHANNEL must name the isolated profile directory
#endif

static void mkdirs(char *path) {
  for (char *p = path + 1; *p; ++p) {
    if (*p == '/') { *p = 0; if (mkdir(path,0700) && errno != EEXIST) { perror(path); exit(1); } *p = '/'; }
  }
  if (mkdir(path,0700) && errno != EEXIST) { perror(path); exit(1); }
}

int main(int argc, char **argv) {
  umask(0077);
  char launcher[PATH_MAX], real[PATH_MAX], binary[PATH_MAX], appini[PATH_MAX], profile[PATH_MAX];
  uint32_t length=sizeof launcher;
  if (_NSGetExecutablePath(launcher,&length) || !realpath(launcher,real)) return 1;
  char *slash=strrchr(real,'/'); if (!slash) return 1; *slash=0;
  if ((size_t)snprintf(binary,sizeof binary,"%s/zen-engine",real) >= sizeof binary ||
      (size_t)snprintf(appini,sizeof appini,"%s/../Resources/browser/personal-application.ini",real) >= sizeof appini) return 1;
  // URLPreloader compares the app omnijar URI against resolved chrome URIs.
  // Parent segments here prevent built_in_addons.json from loading at startup.
  char canonical_appini[PATH_MAX];
  if (!realpath(appini, canonical_appini)) { perror(appini); return 1; }
  const char *userhome=getenv("HOME"); if (!userhome || userhome[0]!='/') return 1;
  if ((size_t)snprintf(profile,sizeof profile,"%s/Library/Application Support/Zen Personal/%s",userhome,PERSONAL_CHANNEL) >= sizeof profile) return 1;
  mkdirs(profile);
  char **args=calloc(argc+9,sizeof(char*)); if (!args) return 1;
  int n=0; args[n++]=binary; args[n++]="-app"; args[n++]=canonical_appini;
  args[n++]="-profile"; args[n++]=profile;
  // The channels have independent remoting identities. Purge only their own caches.
  args[n++]="-purgecaches";
  for (int i=1;i<argc;i++) {
    if (!strcmp(argv[i],"-profile") || !strcmp(argv[i],"--profile") || !strcmp(argv[i],"-P") || !strcmp(argv[i],"-app")) {
      fprintf(stderr,"This app always uses its isolated %s profile.\n",PERSONAL_CHANNEL); return 2;
    }
    args[n++]=argv[i];
  }
  args[n]=NULL; execv(binary,args); perror("execv zen-engine"); return 1;
}
