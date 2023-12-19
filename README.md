linux\_builder
====


Standalone repo for building a linux source tree with CI. This design keeps CI infrastructure, build scripts, and configs
out of the original tree making it easy to see the difference and port it to other kernel versions.


## Usage

### Update submodule

```
cd linux

# Checkout desired branch, pull, etc
git checkout master
git pull

# Go back to project root
cd ..

# Add new commit
git commit -am "Updated linux to ..."

git push
```


### Make new release

To make a new release, tag the repo with a `v*.*` string and push it:

```
git tag v3.1
git push origin v3.1
```

The CI jobs will then build your release and make it available at `https://github.com/panda-re/linux_builder/releases/download/<TAG-NAME>/kernels-latest.tar.gz`
