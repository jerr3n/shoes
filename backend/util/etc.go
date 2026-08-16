package util

// pieces of code that dont make it insufferable to write code

func Prepend[T any](s []T, v T) []T {
	return append([]T{v}, s...)
}
func PrependArray[T any](a1 []T, a2 []T) []T {
	return append(a2, a1...)
}
